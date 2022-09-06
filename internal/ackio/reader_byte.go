package ackio

import (
	"io"

	"github.com/sirkon/mpy6a/internal/errors"
)

// ByteReader реализация вариации на тему io.ByteReader работающая
// поверх Reader и предназначенная для безопасного отката состояния
// чтения.
type ByteReader struct {
	r     *Reader
	count int
}

// ReadByte для реализации io.ByteReader, но:
//
//  * В случае если данных нет и источник закрыт возвращается io.EOF.
//  * В случае если данных нет, но последующие чтения могут их получить,
//    возвращается ошибка такая, что IsReaderNotReady(err) == true.
func (r *ByteReader) ReadByte() (c byte, err error) {
	if r.r.r+r.count != r.r.lim {
		c = r.r.buf[r.r.r+r.count]
		r.count++
		return c, nil
	}

	frame := r.r.frm
	if frame <= 0 {
		frame = missingFrameDefaultSize
	}

	if err := r.r.fulfill(frame); err != nil {
		if err == io.EOF {
			return 0, io.EOF
		}

		return 0, errors.Wrap(err, "fulfill buffer")
	}

	if r.r.r+r.count == r.r.lim {
		return 0, errorReaderNotReady{}
	}

	c = r.r.buf[r.r.r+r.count]
	r.count++
	return c, nil
}

// Commit учёт вычитанного в родительском Reader.
func (r *ByteReader) Commit() {
	r.r.r += r.count
}

// Count возвращает количество байт вычитанных в рамках
// работы данной сущности.
func (r *ByteReader) Count() int {
	return r.count
}

// WrapError дополняет данную ошибку аннотацией и контекстом.
func (r *ByteReader) WrapError(err error, msg string) error {
	return errors.Wrap(err, msg).
		Int64("read-start", r.r.pos+int64(r.r.r)).
		Int64("read-failed-pos", r.r.pos+int64(r.r.r+r.count))
}
