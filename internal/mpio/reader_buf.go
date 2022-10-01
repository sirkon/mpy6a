package mpio

import (
	"bufio"
	"io"

	"github.com/sirkon/mpy6a/internal/errors"
)

// BufReader буферизованная читалка с функцией получения
// текущего числа вычитанных байтов.
type BufReader struct {
	rdr *bufio.Reader
	pos int64
	lim int64

	bufsize int
}

// NewBufReader конструктор BufReader.
func NewBufReader(src io.Reader, opts BufReaderOptionsType) (*BufReader, error) {
	res := &BufReader{
		lim: -1,
	}
	opts.apply(res)

	if res.lim < res.pos {
		return nil, errors.New("got read limit below the read position").
			Int64("invalid-read-position", res.pos).
			Int64("invalid-read-limit", res.lim)
	}

	var reader *bufio.Reader
	if res.bufsize != 0 {
		reader = bufio.NewReaderSize(src, res.bufsize)
	} else {
		reader = bufio.NewReader(src)
	}

	res.rdr = reader
	return res, nil
}

// Read для реализации io.Reader.
func (b *BufReader) Read(p []byte) (n int, err error) {
	if b.lim >= 0 && b.pos >= b.lim {
		return 0, io.EOF
	}

	if b.lim >= 0 && b.pos+int64(len(p)) >= b.lim {
		p = p[:b.lim-b.pos]
	}

	n, err = b.rdr.Read(p)
	b.pos += int64(n)

	return n, err
}

// ReadByte для реализации io.ByteReader.
func (b *BufReader) ReadByte() (c byte, err error) {
	c, err = b.rdr.ReadByte()
	if err == nil {
		b.pos++
	}

	return c, err
}

// Pos возврат позиции чтения.
func (b *BufReader) Pos() int64 {
	return b.pos
}

func (b *BufReader) setBufferSize(v int) {
	b.bufsize = v
}

func (b *BufReader) setReadPosition(v uint64) {
	b.pos = int64(v)
}

func (b *BufReader) setReadLimit(v uint64) {
	b.lim = int64(v)
}
