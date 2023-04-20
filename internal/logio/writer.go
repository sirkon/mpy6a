package logio

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"io"
	"os"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/mpio"
	"github.com/sirkon/mpy6a/internal/types"
	"github.com/sirkon/mpy6a/internal/uvarints"
)

// NewWriter конструктор новой писалки в файл.
// Параметры:
//
//   - name имя файла. Если он уже существует, то будет переоткрыт на чтение и запись.
//   - frame размер кадра. Если файл существует, то этот параметр будет взят из файла.
//   - evlim максимальная длина данных события.
func NewWriter(
	name string,
	frame int,
	evlim int,
	opts ...WriterOption,
) (*Writer, error) {
	eventMayNeed := 16 + uvarints.LengthInt(evlim) + evlim
	if frame < eventMayNeed {
		return nil, errors.Newf("frame is not sufficient to hold every event with the current evlim").
			Int("frame-size", frame).
			Int("event-space", eventMayNeed)
	}
	if frame > frameSizeHardLimit {
		return nil, errors.Newf("frame is too large").
			Int("frame-size", frame).
			Int("maximal-frame-size", frameSizeHardLimit)
	}
	if evlim < 18 {
		return nil, errors.Newf("evlim is too low").
			Int("least-evlim", 18).
			Int("evlim", evlim)
	}

	var file *os.File
	var res Writer
	res.wtnid = types.NewIndexAtomic()

	if _, err := os.Stat(name); err != nil {
		if !os.IsNotExist(err) {
			return nil, errors.Wrap(err, "test existing file")
		}

		// Файла не существует, создаём новый и пишем frame, evlim в его начале.
		file, err = os.OpenFile(name, os.O_CREATE|os.O_WRONLY, 0644)
		if err != nil {
			return nil, errors.Wrap(err, "create new file")
		}

		if err := writeHeader(file, frame, evlim); err != nil {
			return nil, errors.Wrap(err, "write header into a new file")
		}

	} else {
		// Файл существует, читаем параметры frame и evlim из него.
		file, err = os.OpenFile(name, os.O_RDWR, 0644)
		if err != nil {
			return nil, errors.Wrap(err, "open existing file")
		}

		var buf [fileMetaInfoHeaderSize]byte
		n, err := io.ReadFull(file, buf[:])
		if n == 0 && err == io.EOF {
			if err := writeHeader(file, frame, evlim); err != nil {
				return nil, errors.Wrap(err, "write header into an existing empty file")
			}
		} else if err != nil {
			return nil, errors.Wrap(err, "read header of an existing file")
		} else {
			frame = int(binary.LittleEndian.Uint64(buf[:8]))
			evlim = int(binary.LittleEndian.Uint64(buf[8:]))
		}

		stat, err := file.Stat()
		if err != nil {
			return nil, errors.Wrap(err, "get existing file stats")
		}

		lastWrittenID, err := readLastEventID(file, stat, frame)
		if err != nil {
			return nil, errors.Wrap(err, "read last event id")
		}
		res.wtnid.Set(lastWrittenID)

		if _, err := file.Seek(stat.Size(), 0); err != nil {
			return nil, errors.Wrap(err, "seek to the file end")
		}
	}

	res.buf = &bytes.Buffer{}
	res.frame = uint64(frame)
	res.evlim = evlim
	res.zeroes = bytes.Repeat([]byte{0}, eventMayNeed)
	res.pos = fileMetaInfoHeaderSize

	for _, opt := range opts {
		if err := opt.apply(&res, file); err != nil {
			return nil, errors.Wrap(err, "apply "+opt.String())
		}
	}

	if res.bufsize == 0 {
		res.bufsize = defaultBufferCapacityInEvents * eventMayNeed
	}

	res.dst = mpio.NewSimWriterFile(
		file,
		res.pos,
		mpio.SimWriterOptions().BufferSize(res.bufsize).WritePosition(res.pos),
	)

	return &res, nil
}

func readLastEventID(file *os.File, stat os.FileInfo, frame int) (id types.Index, err error) {
	if stat.Size() <= fileMetaInfoHeaderSize {
		// Файл был создан, но записей в него не было.
		return id, nil
	}

	// Получается, запись в файл уже происходила.
	// Нам нужно узнать индекс последней записи.

	diff := stat.Size() - fileMetaInfoHeaderSize
	if diff%int64(frame) == 0 {
		diff--
	}
	off := (diff / int64(frame)) * int64(frame)
	if _, err := file.Seek(off, 0); err != nil {
		return id, errors.Wrap(err, "seek to the start")
	}

	rdr := io.LimitReader(file, int64(frame))
	bufrdr := bufio.NewReader(rdr)

	var buf [16]byte
	for {
		if _, err := io.ReadFull(bufrdr, buf[:]); err != nil {
			switch err {
			case io.EOF, io.ErrUnexpectedEOF:
				return id, nil
			default:
				if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
					return id, nil
				}

				return id, errors.Wrap(err, "read next event data")
			}
		}

		nid := types.IndexDecode(buf[:])
		if nid.Term == 0 {
			// Предыдущая запись была последней.
			return id, nil
		}
		id = nid

		// Надо пропустить содержимое записи.
		length, err := binary.ReadUvarint(bufrdr)
		if err != nil {
			return id, errors.Wrap(err, "read event data length to pass").Stg("invalid-event-id", id)
		}

		if _, err := bufrdr.Discard(int(length)); err != nil {
			return id, errors.Wrap(err, "skip encoded content of the event").Stg("invalid-event-id", id)
		}
	}
}

// Writer писалка логов.
type Writer struct {
	dst    *mpio.SimWriter
	buf    *bytes.Buffer
	zeroes []byte
	wtnid  types.IndexAtomic

	frame   uint64
	evlim   int
	pos     uint64
	lastid  types.Index
	bufsize int
}

// WriteEvent запись события с данным идентификатором.
// Возвращает размер всех записанных данных.
func (w *Writer) WriteEvent(id types.Index, data []byte) (int, error) {
	if len(data) > w.evlim {
		return 0, errorEventTooLarge{
			evlim: w.evlim,
			rec:   data,
		}
	}

	var deltapos int
	l := eventLength(data)
	framerest := int(w.frame - (w.pos-fileMetaInfoHeaderSize)%w.frame)

	if framerest < l {
		if framerest > len(w.zeroes) {
			w.zeroes = make([]byte, framerest)
		}

		deltapos = framerest
		if _, err := w.dst.Write(w.zeroes[:framerest]); err != nil {
			return 0, errors.Wrapf(err, "push zeroes at the end of a frame")
		}
	}

	// Сериализация и запись в лог идентификатора и события.
	var buf [16]byte
	types.IndexEncode(buf[:], id)
	w.buf.Reset()
	w.buf.Write(buf[:])
	ll := binary.PutUvarint(buf[:], uint64(len(data)))
	w.buf.Write(buf[:ll])
	w.buf.Write(data)

	flushed, err := w.dst.WriteFA(w.buf.Bytes())
	if err != nil {
		return 0, errors.Wrap(err, "push encoded event data")
	}

	if flushed {
		// Данные были сброшены, нужно обновить индекс сброшенной записи.
		w.wtnid.Set(w.lastid)
	}
	deltapos += l
	w.pos += uint64(deltapos)
	w.lastid = id

	return deltapos, nil
}

func eventLength(data []byte) int {
	return 16 + uvarints.LengthInt(len(data)) + len(data)
}

// Flush сброс буфера.
func (w *Writer) Flush() error {
	if err := w.flush(); err != nil {
		return err
	}

	return nil
}

// LookupNext поиск события следующего за данным.
func (w *Writer) LookupNext(id types.Index, logger func(err error)) (LookupResult, error) {
	if types.IndexLess(w.wtnid.Get(), id) {
		// Ищется запись с индексом, которая ещё не попала (с гарантией) на диск.
		// Поиск мы осуществляем только в самом файле, поэтому в данном случае
		// нужно принудительно сбросить накопленные данные.
		if err := w.dst.Flush(); err != nil {
			// Так как искомые данные могут находиться не в файле, а в буфере.
			// Пока полагаемся на то, что данная операция (поиска) не будет частой,
			// особенно в случае сброса с синхронизацией, которая ну никак
			// не блещет скоростью.
			return nil, errors.Wrap(err, "flush existing data")
		}
	}

	res, err := LookupNext(w.dst.Name(), id, logger)
	if err != nil {
		return nil, errors.Wrap(err, "look for the next event in the file")
	}

	return res, nil
}

// Close закрытие записи лога.
func (w *Writer) Close() error {
	return w.dst.Close()
}

// Pos текущая позиция записи в файл.
func (w *Writer) Pos() uint64 {
	return w.pos
}

func (w *Writer) flush() error {
	if err := w.dst.Flush(); err != nil {
		return err
	}

	w.wtnid.Set(w.lastid)

	return nil
}

func writeHeader(dst io.WriteCloser, frame, limit int) error {
	var buf [fileMetaInfoHeaderSize]byte
	binary.LittleEndian.PutUint64(buf[:8], uint64(frame))
	binary.LittleEndian.PutUint64(buf[8:], uint64(limit))
	if _, err := dst.Write(buf[:]); err != nil {
		return errors.Wrap(err, "write log file header")
	}

	return nil
}
