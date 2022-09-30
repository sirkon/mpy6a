package logio

import (
	"bufio"
	"os"
)

type fileBuf struct {
	buf *bufio.Reader
	src *os.File
}

// ReadByte для реализации logReader.
func (f *fileBuf) ReadByte() (byte, error) {
	return f.buf.ReadByte()
}

// Read для реализации logReader.
func (f *fileBuf) Read(p []byte) (n int, err error) {
	return f.buf.Read(p)
}

// Close для реализации logReader.
func (f *fileBuf) Close() error {
	return f.src.Close()
}

var (
	_ logReader = &fileBuf{}
)
