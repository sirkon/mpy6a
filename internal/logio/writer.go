package logio

import (
	"bytes"
	"encoding/binary"
	"io"
	"os"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/types"
	"github.com/sirkon/mpy6a/internal/uvarints"
)

// NewWriter конструктор новой писалки в файл.
// Параметры:
//
//  - name имя файла. Если он уже существует, то будет переоткрыт на чтение и запись.
//  - frame размер кадра. Если файл существует, то этот параметр будет взят из файла.
//  - limit максимальная длина данных события.
func NewWriter(
	name string,
	frame int,
	limit int,
	opts ...WriterOption,
) (*Writer, error) {
	eventMayNeed := 16 + uvarints.LengthInt(limit) + limit
	if frame < eventMayNeed {
		return nil, errors.Newf("frame is not sufficient to hold every event with the current limit").
			Int("frame-size", frame).
			Int("event-space", eventMayNeed)
	}
	if frame > frameSizeHardLimit {
		return nil, errors.Newf("frame is too large").
			Int("frame-size", frame).
			Int("maximal-frame-size", frameSizeHardLimit)
	}
	if limit < 18 {
		return nil, errors.Newf("limit is too low").
			Int("least-limit", 18).
			Int("limit", limit)
	}

	var file *os.File
	var res Writer

	if _, err := os.Stat(name); err != nil {
		if !os.IsNotExist(err) {
			return nil, errors.Wrap(err, "test existing file")
		}

		// Файла не существует, создаём новый и пишем frame, limit в его начале.
		file, err = os.OpenFile(name, os.O_CREATE|os.O_WRONLY, 0644)
		if err != nil {
			return nil, errors.Wrap(err, "create new file")
		}

		if err := writeHeader(file, frame, limit); err != nil {
			return nil, errors.Wrap(err, "write header into a new file")
		}
	} else {
		// Файл существует, читаем параметры frame и limit из него.
		file, err = os.OpenFile(name, os.O_RDWR, 0644)
		if err != nil {
			return nil, errors.Wrap(err, "open existing file")
		}

		var buf [16]byte
		n, err := io.ReadFull(file, buf[:])
		if n == 0 && err == io.EOF {
			if err := writeHeader(file, frame, limit); err != nil {
				return nil, errors.Wrap(err, "write header into an existing empty file")
			}
		} else if err != nil {
			return nil, errors.Wrap(err, "read header of an existing file")
		} else {
			frame = int(binary.LittleEndian.Uint64(buf[:8]))
			limit = int(binary.LittleEndian.Uint64(buf[8:]))
		}
	}

	res.dst = file
	res.frame = uint64(frame)
	res.limit = limit
	res.zeroes = bytes.Repeat([]byte{0}, eventMayNeed)
	res.pos = 16

	for _, opt := range opts {
		if err := opt.apply(&res, file); err != nil {
			return nil, errors.Wrap(err, "apply "+opt.String())
		}
	}

	if res.buf == nil {
		// Не был задан буфер, создаём его сами.
		res.buf = &bytes.Buffer{}
		res.buf.Grow(defaultBufferCapacityInEvents * eventMayNeed)
	}

	return &res, nil
}

// Writer писалка логов.
type Writer struct {
	dst    io.WriteCloser
	buf    *bytes.Buffer
	zeroes []byte

	frame uint64
	limit int
	pos   uint64
}

// WriteEvent запись события с данным идентификатором.
func (w *Writer) WriteEvent(id types.Index, data []byte) (int, error) {
	if len(data) > w.limit {
		return 0, errorEventTooLarge{
			limit: w.limit,
			rec:   data,
		}
	}

	var deltapos uint64
	l := 16 + uvarints.LengthInt(len(data)) + len(data)
	framerest := int(w.frame - ((w.pos - 16) % w.frame))

	if framerest < l {
		// Новая запись не поместится в кадре лога.
		// Далее мы разбираем три случая:
		//
		//  - Нули кадра лога поместятся в буфер.
		//  - Нули кадра лога в принципе не поместятся в буфере.
		//  - В принципе, они полезут.

		if framerest+w.buf.Len() >= w.buf.Cap() {
			if err := w.flush(); err != nil {
				return 0, errors.Wrap(err, "flush buffer before frame end zeroes write")
			}
		}

		w.buf.Write(w.zeroes[:framerest])
		deltapos += uint64(framerest)
	}

	if w.buf.Len()+l < w.buf.Cap() {
		// Если в буфере недостаточно места записи события, то сбрасываем его.
		if err := w.flush(); err != nil {
			return 0, errors.Wrap(err, "flush buffer before event write")
		}
	}

	// Сериализация и запись в лог идентификатора и события.
	var buf [16]byte
	types.IndexEncode(buf[:], id)
	w.buf.Write(buf[:])
	ll := binary.PutUvarint(buf[:], uint64(len(data)))
	w.buf.Write(buf[:ll])
	w.buf.Write(data)
	deltapos += uint64(l)
	w.pos += deltapos

	return int(deltapos), nil
}

// Flush сброс буфера.
func (w *Writer) Flush() error {
	if err := w.flush(); err != nil {
		return err
	}

	return nil
}

// Close закрытие записи лога.
func (w *Writer) Close() error {
	if err := w.flush(); err != nil {
		return errors.Wrap(err, "flush buffer")
	}

	if err := w.dst.Close(); err != nil {
		return errors.Wrap(err, "close writer")
	}

	return nil
}

// Pos текущая позиция записи в файл.
func (w *Writer) Pos() uint64 {
	return w.pos
}

func (w *Writer) flush() error {
	if w.buf.Len() == 0 {
		return nil
	}

	if _, err := w.dst.Write(w.buf.Bytes()); err != nil {
		return err
	}

	w.buf.Reset()
	return nil
}

func writeHeader(dst io.WriteCloser, frame, limit int) error {
	var buf [16]byte
	binary.LittleEndian.PutUint64(buf[:8], uint64(frame))
	binary.LittleEndian.PutUint64(buf[8:], uint64(limit))
	if _, err := dst.Write(buf[:]); err != nil {
		return errors.Wrap(err, "write log file header")
	}

	return nil
}
