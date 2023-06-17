package sourceio

import (
	"encoding/binary"
	"io"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/types"
	"github.com/sirkon/varsize"
)

// NewWriter конструктор писалки
func NewWriter(dst io.Writer, size int) *Writer {
	return &Writer{
		dst: dst,
		buf: make([]byte, 0, size),
	}
}

// Writer запись данных сохранённых сессий.
type Writer struct {
	dst io.Writer
	buf []byte
}

// Write для реализации io.Writer.
func (w *Writer) Write(p []byte) (n int, err error) {
	if cap(w.buf)-len(w.buf) < len(p) {
		if err := w.flush(); err != nil {
			return 0, errors.Wrap(err, "dump previously collected session")
		}
	}

	if len(p) > cap(w.buf) {
		write, err := w.dst.Write(p)
		if err != nil {
			return write, errors.Wrap(err, "write session straight")
		}

		return write, nil
	}

	w.buf = append(w.buf, p...)
	return len(p), nil
}

// SaveRawSession сохранение закодированных данных сессии с заданным
// временем повтора.
func (w *Writer) SaveRawSession(repeat uint64, data []byte) error {
	ll := 8 + varsize.Len(data) + len(data)
	if cap(w.buf)-len(w.buf) < ll {
		if err := w.flush(); err != nil {
			return errors.Wrap(err, "flush buffer")
		}
	}

	if cap(w.buf) < ll {
		w.buf = make([]byte, 0, ll)
	}

	w.buf = binary.LittleEndian.AppendUint64(w.buf, repeat)
	w.buf = binary.AppendUvarint(w.buf, uint64(len(data)))
	w.buf = append(w.buf, data...)

	return nil
}

// SaveSession сохранение сессии с заданным временем повтора.
func (w *Writer) SaveSession(repeat uint64, sess *types.Session) error {
	l := types.SessionRawLen(sess)
	ll := 8 + varsize.Uint(uint64(l)) + l
	if cap(w.buf)-len(w.buf) < ll {
		// Остатка буфера не хватает для вмещения записи целиком.
		// Далее есть два варианта:
		//  - Даже сброшенного буфера не хватит на запись. В этом случае
		//    сбрасываем буфер в файл (если он не пуст) и расширяем до
		//    необходимого размера.
		//  - Если буфер сбросить, то его станет хватать.
		if err := w.flush(); err != nil {
			return errors.Wrap(err, "flush buffer")
		}

		if cap(w.buf) < ll {
			w.buf = make([]byte, 0, ll)
		}
	}

	w.buf = binary.LittleEndian.AppendUint64(w.buf, repeat)
	w.buf = binary.AppendUvarint(w.buf, uint64(l))
	w.buf = types.SessionEncode(w.buf, sess)

	return nil
}

// Flush сбрасывает остаток данных.
func (w *Writer) Flush() error {
	if err := w.flush(); err != nil {
		return errors.Wrap(err, "dump collected session")
	}

	return nil
}

func (w *Writer) flush() error {
	if len(w.buf) == 0 {
		return nil
	}

	if _, err := w.dst.Write(w.buf); err != nil {
		return err
	}

	w.buf = w.buf[:0]
	return nil
}
