package storage

import (
	"encoding/binary"
	"os"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/types"
)

// Log возвращает ручку для операций записи в лог.
func (s *Storage) Log() Log {
	return Log{
		s: s,
	}
}

// Log сущность представляющая операции записи в лог.
type Log struct {
	s *Storage
}

// Сущность для ведения лога операций.
type oplog struct {
	dst   *os.File
	frame uint64

	buf   []byte
	fsize uint64
}

func newOplog(name string, last, framesize uint64) (*oplog, error) {
	file, err := os.OpenFile(name, os.O_RDWR, 0644)
	if err != nil {
		if !os.IsNotExist(err) {
			return nil, errors.Wrap(err, "open existing log file")
		}

		// файл должен существовать
		if last > 0 {
			return nil, errors.New("log file known to exist was not found")
		}

		// файла не существует, создаём новый
		file, err = os.OpenFile(name, os.O_RDWR|os.O_CREATE, 0644)

		// пишем заголовок с размером кадра
		var buf [8]byte
		binary.LittleEndian.PutUint64(buf[:8], framesize)
		if _, err := file.Write(buf[:8]); err != nil {
			return nil, errors.Wrap(err, "write frame size header")
		}

		last = 8
	} else {
		// файл открыт, читаем размер кадра и сдвигаемся на нужную позицию
		var buf [8]byte
		read, err := file.Read(buf[:8])
		if err != nil {
			return nil, errors.Wrap(err, "Read frame size header")
		}

		if read < cap(buf) {
			return nil, errors.Newf(
				"corrupted frame size header: needed at at least %d bytes in the file, got %d",
				cap(buf),
				read,
			)
		}

		framesize = binary.LittleEndian.Uint64(buf[:8])

		// сдвигаемся на текущую позицию для записи
		if last > 0 {
			if _, err := file.Seek(int64(last), 0); err != nil {
				return nil, errors.Wrapf(err, "seek to the current write position %d", last)
			}
		}
	}

	return &oplog{
		dst:   file,
		frame: framesize,
		buf:   make([]byte, framesize),
		fsize: last,
	}, nil
}

// Write добавление новой операции
func (l *oplog) Write(id types.Index, data []byte) error {
	// Выясняем, полезут ли данные следующей сессии в текущий кадр
	v := (l.fsize - 8) % l.frame

	var length int
	var needLeadingZeroes bool
	if int(v)+20+len(data) > int(l.frame) {
		// Не полезут, т.е. вначале нужно заполнить конец кадра нулями,
		// и только за ними сессию.
		length = int(l.frame-v) + 20 + len(data)
		needLeadingZeroes = true
	} else {
		length = 20 + len(data)
	}

	if length+len(l.buf) > cap(l.buf) {
		if err := l.flush(); err != nil {
			return errors.Wrap(err, "flush buffered data")
		}
	}

	prevlen := len(l.buf)
	l.buf = l.buf[:len(l.buf)+length]
	buf := l.buf[prevlen:]
	if needLeadingZeroes {
		d := int(l.frame - v)
		buf[d-1] = 0 // убираем проверку границ
		for i := 0; i < d; i++ {
			buf[i] = 0
		}
		types.IndexEncode(buf[d:], id)
		binary.LittleEndian.PutUint32(buf[d+16:], uint32(len(data)))
		copy(buf[d+20:], data)
	} else {
		types.IndexEncode(buf, id)
		binary.LittleEndian.PutUint32(buf[16:], uint32(len(data)))
		copy(buf[20:], data)
	}

	l.fsize += uint64(length)
	return nil
}

// Close закрытие лога.
func (l *oplog) Close() error {
	if err := l.flush(); err != nil {
		return errors.Wrap(err, "flush buffered data")
	}

	if err := l.dst.Close(); err != nil {
		return errors.Wrap(err, "Close underlying file")
	}

	return nil
}

// Сброс буфера на диск.
func (l *oplog) flush() error {
	if len(l.buf) == 0 {
		return nil
	}

	if _, err := l.dst.Write(l.buf); err != nil {
		return err
	}

	l.buf = l.buf[:0]

	return nil
}
