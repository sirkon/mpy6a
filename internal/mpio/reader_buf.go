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

// NewBufReader конструктор BufReader. Паникует при попытке установки
// начальной позиции чтения выше ограничения.
func NewBufReader(src io.Reader, opts ...Option[*BufReader]) *BufReader {
	res := &BufReader{
		lim: -1,
	}

	for _, opt := range opts {
		opt(res, prohibitCustomOpts{})
	}

	var reader *bufio.Reader
	if res.bufsize != 0 {
		reader = bufio.NewReaderSize(src, res.bufsize)
	} else {
		reader = bufio.NewReader(src)
	}

	res.rdr = reader
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

// PosRead возврат позиции чтения.
func (b *BufReader) PosRead() int64 {
	return b.pos
}

func (b *BufReader) setBufferSize(n int) {
	b.bufsize = n
}

func (b *BufReader) setReadPosition(pos int64) {
	if pos < b.lim {
		panic(errors.Newf("start read position must not be lower than a read limit"))
	}
	b.pos = pos
}

func (b *BufReader) setReadLimitPosition(lim int64) {
	if b.pos > lim {
		panic(errors.Newf("read limit must not be lower than a start read position"))
	}
	b.lim = lim
}
