package mpio

import (
	"bufio"
	"io"
)

// BufReader буферизованная читалка с функцией получения
// текущего числа вычитанных байтов.
type BufReader struct {
	rdr *bufio.Reader
	pos int64
	lim int64
}

// NewBufReader конструктор BufReader.
func NewBufReader(src io.Reader, opts BufReaderOptions) *BufReader {
	res := &BufReader{
		lim: -1,
	}

	var reader *bufio.Reader
	if opts.BufferSize != 0 {
		reader = bufio.NewReaderSize(src, opts.BufferSize)
	} else {
		reader = bufio.NewReader(src)
	}

	res.rdr = reader
	res.pos = int64(opts.ReadPosition)
	return res
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
