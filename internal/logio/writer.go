package logio

import (
	"encoding/binary"
	"os"

	"github.com/sirkon/mpy6a/internal/errors"
)

// Log сущность для записи бинарных данных в лог.
type Log struct {
	file      *os.File
	buf       []byte
	splitbuf  []byte
	cur       uint64
	nobuf     bool
	fsync     bool
	framesize uint64
	frameleft uint64
}

// NewLog открытие лога в файле с данным именем с заданной начальной позицией в нём.
func NewLog(name string, cur, framesize, maxrecordsize uint64, nobuf, fsync bool) (*Log, error) {
	file, framesize, err := openOrCreateFile(name, framesize)
	if err != nil {
		return nil, errors.Wrapf(err, "open or create file '%s'", name)
	}

	if cur != 0 {
		if _, err := file.Seek(int64(cur), 0); err != nil {
			return nil, errors.Wrap(err, "seek to the given position")
		}
	} else {
		cur = 8
	}

	res := &Log{
		file:      file,
		cur:       cur,
		buf:       make([]byte, 0, maxrecordsize*3+96),
		splitbuf:  make([]byte, maxrecordsize*2+64),
		nobuf:     nobuf,
		fsync:     fsync,
		framesize: framesize,
		frameleft: (cur - 8) % framesize,
	}

	return res, nil
}

// WriteEvent запись в лог сериализованного события.
// Возвращает текущую позицию в нём после успешной записи.
func (l *Log) WriteEvent(term, index uint64, event []byte) (pos uint64, err error) {
	if len(event) == 0 {
		return l.cur, nil
	}

	if l.nobuf {
		if cap(l.buf) < 32+len(event) {
			l.buf = make([]byte, len(event)+32)
		}
		l.buf = l.buf[:32+len(event)]
		binary.LittleEndian.PutUint64(l.buf[:8], term)
		binary.LittleEndian.PutUint64(l.buf[8:16], index)
		eventlenlen := binary.PutUvarint(l.buf[16:], uint64(len(event)))
		copy(l.buf[16+eventlenlen:], event)
		l.buf = l.buf[:16+eventlenlen+len(event)]

		var buf []byte
		if uint64(len(l.buf)) <= l.frameleft {
			buf = l.buf
			l.framesize -= uint64(len(l.buf))
		} else {
			buf = l.splitbuf[:l.frameleft+uint64(len(l.buf))]
			memclr(buf[:l.frameleft])
			copy(buf[l.frameleft:], l.buf)
			l.frameleft = l.framesize - uint64(len(l.buf))
		}

		if _, err := l.file.Write(buf); err != nil {
			return 0, errors.Wrap(err, "save event without buffering")
		}

		if l.fsync {
			if err := l.file.Sync(); err != nil {
				return 0, errors.Wrap(err, "sync save event without buffering")
			}
		}

		l.cur += uint64(len(buf))

		return l.cur, nil
	}

	var eventlen []byte
	{
		var buf [16]byte
		sesslenlen := binary.PutUvarint(buf[:16], uint64(len(event)))
		eventlen = buf[:sesslenlen]
	}

	var packlen int
	justlen := 16 + len(eventlen) + len(event)
	var offlen int
	if uint64(justlen) <= l.frameleft {
		packlen = justlen
	} else {
		offlen = int(l.frameleft)
		packlen = int(l.frameleft) + justlen
		l.frameleft = l.framesize
	}

	if len(l.buf)+packlen > cap(l.buf) {
		if err := l.flush(); err != nil {
			return 0, errors.Wrap(err, "flush buffer")
		}
	}

	s := len(l.buf)
	l.buf = l.buf[:s+packlen]
	memclr(l.buf[s : s+offlen])
	binary.LittleEndian.PutUint64(l.buf[s+offlen:], term)
	binary.LittleEndian.PutUint64(l.buf[s+offlen+8:], term)
	copy(l.buf[s+offlen+16:], eventlen)
	copy(l.buf[s+offlen+16+len(eventlen):], event)
	l.frameleft -= uint64(justlen)
	l.cur += uint64(packlen)

	return l.cur, nil
}

// Close закрытие лога
func (l *Log) Close() error {
	if !l.nobuf {
		if err := l.flush(); err != nil {
			return errors.Wrap(err, "flush the rest buffered data")
		}
	}

	if err := l.file.Close(); err != nil {
		return errors.Wrap(err, "close file")
	}

	return nil
}

// Position текущий размер записываемого файла.
func (l *Log) Position() uint64 {
	return l.cur
}

func (l *Log) flush() error {
	if len(l.buf) == 0 {
		return nil
	}

	if _, err := l.file.Write(l.buf); err != nil {
		return errors.Wrap(err, "save buffered data")
	}

	if l.fsync {
		if err := l.file.Sync(); err != nil {
			return errors.Wrap(err, "sync saved buffered data")
		}
	}

	l.buf = l.buf[:0]

	return nil
}

func openOrCreateFile(name string, frameSize uint64) (*os.File, uint64, error) {
	file, err := os.OpenFile(name, os.O_WRONLY, 0644)
	if err != nil && !os.IsNotExist(err) {
		return nil, 0, errors.Wrapf(err, "try to open existing file")
	} else if err != nil && os.IsNotExist(err) {
		file, err = os.OpenFile(name, os.O_RDWR|os.O_CREATE, 0644)
		if err != nil {
			return nil, 0, errors.Wrapf(err, "create file")
		}

		var buf [8]byte
		binary.LittleEndian.PutUint64(buf[:8], frameSize)
		if _, err := file.Write(buf[:8]); err != nil {
			return nil, 0, errors.Wrapf(err, "push frame size header in the just created file")
		}

		return file, frameSize, nil
	}

	// файл существует, нужно узнать размер кадра
	var frameBuf [8]byte
	l, err := file.Read(frameBuf[:8])
	if err != nil {
		return nil, 0, errors.Wrapf(err, "read frame size in existing file")
	}
	if l < 8 {
		return nil, 0, errors.New("missing header with frame size in the file")
	}

	return file, binary.LittleEndian.Uint64(frameBuf[:8]), nil
}

// memclr заполнение участка памяти нулями
func memclr(buf []byte) {
	for i := range buf {
		buf[i] = 0
	}
}
