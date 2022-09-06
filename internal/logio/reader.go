package logio

import (
	"bufio"
	"encoding/binary"
	"io"

	"github.com/sirkon/mpy6a/internal/errors"
)

// LogReader сущность для чтения бинарных данных из логов,
// предоставляющая интерфейс итератора, чтения начинается с заданной
// позиции в первом файле, продолжается по всем файлам и заканчивается
// на заданной позиции в последнем файле.
type LogReader struct {
	sources []LogReadSource
	curFile namedReadCloser
	reader  *bufio.Reader

	term    uint64
	index   uint64
	event   []byte
	zerobuf []byte

	framesize uint64
	frameleft uint64

	err error
}

// NewLogReader конструктор итератора по записям лога.
func NewLogReader(sources []LogReadSource) (*LogReader, error) {
	if len(sources) == 0 {
		return &LogReader{}, nil
	}

	file, framesize, frameleft, err := sources[0](logFileProviderProtector{})
	if err != nil {
		return nil, errors.Wrap(err, "open first file")
	}

	res := &LogReader{
		sources:   sources[1:],
		curFile:   file,
		reader:    bufio.NewReader(file),
		err:       nil,
		framesize: framesize,
		frameleft: frameleft,
	}

	return res, nil
}

// Next попытка вычитки следующего куска данных
func (r *LogReader) Next() bool {
	if r.err != nil {
		return false
	}

start:
	var buf [16]byte
	bufread, err := r.reader.Read(buf[:16])
	if err != nil {
		if err == io.EOF && bufread == 0 {
			switched, err := r.switchFile()
			if err != nil {
				r.err = errors.Wrapf(err, "switch to the next file after state index read")
				return false
			}

			if !switched {
				r.err = io.EOF
				return false
			}

			goto start
		}

		r.err = errors.Wrapf(err, "read state index of the next event")
		return false
	}

	if bufread < 16 {
		r.err = errors.Newf(
			"read malformed state index in the %s: 16 bytes expected, got %d",
			r.curFile.Name(),
			bufread,
		)
		return false
	}
	r.term = binary.LittleEndian.Uint64(buf[:8])
	if r.term == 0 {
		// кадр завершён, нужно перескочить на следующий
		delta := int(r.frameleft) - 16
		if cap(r.zerobuf) < delta {
			r.zerobuf = make([]byte, delta)
		} else {
			r.zerobuf = r.zerobuf[:delta]
		}

		if _, err := io.ReadFull(r.reader, r.zerobuf); err != nil {
			r.err = errors.Wrapf(err, "read end of frame at %d in %s", r.curFile.Name())
		}

		r.frameleft = r.framesize
		goto start
	}
	r.index = binary.LittleEndian.Uint64(buf[8:16])

	eventlen, err := binary.ReadUvarint(r.reader)
	if err != nil {
		r.err = errors.Wrapf(err, "read malformed event length in the %s", r.curFile.Name())
		return false
	}

	if cap(r.event) >= int(eventlen) {
		r.event = r.event[:eventlen]
	} else {
		r.event = make([]byte, eventlen)
	}

	gotlen, err := r.reader.Read(r.event)
	if err != nil {
		if err == io.EOF {
			if int(eventlen) == gotlen {
				switched, err := r.switchFile()
				if err != nil {
					r.err = errors.Wrap(err, "switch to the next file after event read")
					return false
				}

				if !switched {
					r.err = io.EOF
				}

				return true
			}

			r.err = errors.Wrapf(
				err,
				"read malformed event in the end of %s: %d bytes expected, got %d",
				r.curFile.Name(),
				eventlen,
				gotlen,
			)
			return false
		}

		r.err = errors.Newf("read event data length %d from %s", eventlen, r.curFile.Name())
		return false
	}

	return true
}

// Event возвращает срок, индекс в сроке и бинарные данные вычитанного события.
// Внимание: возвращаемый слайс байтов может быть перезаписан
//           в ходе последующих итераций, копируйте его если
//           используете именно слайс байтов без конвертаций.
func (r *LogReader) Event() (term uint64, index uint64, event []byte) {
	return r.term, r.index, r.event
}

// Err диагностирует ошибку
func (r *LogReader) Err() error {
	if r.err != io.EOF {
		return r.err
	}

	return nil
}

// Close закрывает текущие ресурсы и останавливает итерацию
func (r *LogReader) Close() error {
	if r.curFile != nil {
		if err := r.curFile.Close(); err != nil {
			return errors.Wrap(err, "close "+r.curFile.Name())
		}
	}

	if r.err == nil {
		r.err = io.EOF
	}

	return nil
}

// switchFile попытка переключения на следующий файл.
// Возвращает err == io.EOF если файлов больше не осталось.
func (r *LogReader) switchFile() (bool, error) {
	if err := r.curFile.Close(); err != nil {
		return false, errors.Wrap(err, "close "+r.curFile.Name())
	}

	r.curFile = nil

	if len(r.sources) == 0 {
		return false, nil
	}

	head, rest := r.sources[0], r.sources[1:]
	r.sources = rest

	file, framsize, frameleft, err := head(logFileProviderProtector{})
	if err != nil {
		return false, errors.Wrap(err, "open next file")
	}

	r.curFile = file
	r.framesize = framsize
	r.frameleft = frameleft
	r.reader.Reset(file)

	return true, nil
}
