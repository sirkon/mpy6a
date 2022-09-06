package sbuffer

import (
	"bytes"
	"io"

	"github.com/sirkon/mpy6a/internal/errors"
)

// FlushingWriter определение писалки с функцией сброса.
type FlushingWriter interface {
	io.Writer
	Flush() error
}

// New конструктор SteadyBuffer с размером буфера по-умолчанию.
func New(w FlushingWriter) *SteadyBuffer {
	return newSteadyBuffer(w, defaultSize)
}

// NewSize конструктор SteadyBuffer с размером буфера указываемым пользователем.
func NewSize(w FlushingWriter, size int) *SteadyBuffer {
	return newSteadyBuffer(w, size)
}

// SteadyBuffer буфер гарантирующий неделимость записываемых в
// рамках одного вызова Write данных при сбросе в низлежащую
// писалку.
type SteadyBuffer struct {
	dest FlushingWriter
	data *bytes.Buffer
	size int
}

// Write для реализации io.Writer
func (b *SteadyBuffer) Write(p []byte) (n int, err error) {
	if len(p)+b.data.Len() > b.size {
		if err := b.flush(); err != nil {
			return 0, errors.Wrap(err, "flush previously collected data as it grown large enough")
		}
	}

	if len(p) >= b.size {
		if n, err := b.dest.Write(p); err != nil {
			return n, errors.Wrap(err, "write package directly as it turned to be too large")
		}

		return 0, nil
	}

	if _, err := b.data.Write(p); err != nil {
		return 0, errors.Wrap(err, "buffer incoming data")
	}

	return len(p), nil
}

// Flush принудительный сброс данных в dest.
func (b *SteadyBuffer) Flush() error {
	return b.flush()
}

func (b *SteadyBuffer) flush() error {
	if b.data.Len() > 0 {
		if _, err := b.dest.Write(b.data.Bytes()); err != nil {
			return errors.Wrap(err, "dump buffered data")
		}
		b.data.Reset()
	}

	if err := b.dest.Flush(); err != nil {
		return errors.Wrap(err, "force flush")
	}

	return nil
}

func newSteadyBuffer(w FlushingWriter, size int) *SteadyBuffer {
	var buf bytes.Buffer
	buf.Grow(size)
	return &SteadyBuffer{
		dest: w,
		data: &buf,
		size: size,
	}
}
