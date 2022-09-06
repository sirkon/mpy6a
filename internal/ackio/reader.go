package ackio

import (
	"io"

	"github.com/sirkon/mpy6a/internal/errors"
)

// Reader читалка из источника с функциональностью
// подтверждения вычитки или отката к началу неподтверждённых
// вычитанных данных.
type Reader struct {
	src io.Reader
	buf []byte
	frm int

	pos int64
	ur  int
	r   int
	lim int
	eof bool
}

// New конструктор читалки с данным источником и опциями.
func New(src io.Reader, opts ...ReaderOpt) *Reader {
	r := &Reader{
		src: src,
	}
	for _, opt := range opts {
		opt(r, readerOptRestriction{})
	}

	return r
}

// Read для реализации io.Reader.
func (r *Reader) Read(p []byte) (n int, err error) {
	if len(p) == 0 {
		return 0, nil
	}

	if !r.exhausted() {
		// В буфере ещё есть данные, возвращаем их даже если
		// длина непрочитанной части буфера меньше чем у p.
		n = r.lim - r.r
		if n > len(p) {
			n = len(p)
		}

		copy(p, r.buf[r.r:r.r+n])
		r.r += n
		return n, nil
	}

	frame := r.frm
	if frame <= 0 {
		frame = missingFrameDefaultSize
	}
	if err := r.fulfill(frame); err != nil {
		// Вычитка не удалась, выходим.
		return 0, err
	}

	if r.exhausted() {
		// Данных в источнике может и не быть, если это так, то выходим.
		return 0, nil
	}

	n = r.lim - r.r
	if n > len(p) {
		n = len(p)
	}

	copy(p, r.buf[r.r:r.r+n])
	r.r += n
	return n, nil
}

// Ack подтверждение вычитки n байт. Очень желательно "схлопывать" несколько
// последовательных Ack-ов в один, т.к. при этом производится копирование
// буфера.
func (r *Reader) Ack(n int) error {
	if n <= 0 {
		return errors.New("acknowledge must be positive").Int("invalid-acknowledge-value", n)
	}

	if n > r.lim {
		return errors.New("acknowledge must not go outside of the buffer").
			Int("invalid-acknowledge-value", n).
			Int("current-buffer-size", r.lim)
	}

	r.ur += n
	r.pos += int64(n)
	copy(r.buf, r.buf[r.ur:r.lim])
	r.ur, r.r, r.lim = 0, r.ur-r.r, r.lim-r.ur

	return nil
}

// Rollback откат позиции чтения в начало неподтверждённых данных.
func (r *Reader) Rollback() {
	r.r = r.ur
}

// ByteReader возврат байтовой читалки буфера.
func (r *Reader) ByteReader() ByteReader {
	return ByteReader{
		r:     r,
		count: 0,
	}
}

// Pos позиция конца подтверждённой вычитки.
func (r *Reader) Pos() int64 {
	return r.pos
}

// Заполнение буфера очередной порцией данных с указанием их
// минимального предполагаемого размера.
func (r *Reader) fulfill(n int) error {
	if r.eof {
		return io.EOF
	}

	if cap(r.buf)-r.lim < n {
		// В остатке буфере осталось недостаточно места, чтобы поместить
		// все n байт.
		buf := make([]byte, cap(r.buf)+n)
		copy(buf, r.buf[r.ur:r.lim])
		r.ur, r.r, r.lim = 0, r.r-r.ur, r.lim-r.ur
		r.buf = buf
	}

	read, err := r.src.Read(r.buf[r.lim:cap(r.buf)])
	if err != nil {
		if err == io.EOF {
			r.eof = true

			if read > 0 {
				r.lim += read
				return nil
			}
		}

		return err
	}

	r.lim += read
	return nil
}

// Возвращает true если буфер пуст или если все данные оттуда уже были
// вычитаны.
func (r *Reader) exhausted() bool {
	return r.r == r.lim
}
