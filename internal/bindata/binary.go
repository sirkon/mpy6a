package bindata

import (
	"bufio"
	"encoding/binary"
	"io"

	"github.com/sirkon/mpy6a/internal/errors"
)

// EncodeBinary сериализация бинарных данных в указанный приёмник.
func EncodeBinary(dst *bufio.Writer, data []byte) error {
	var buf [16]byte
	size := binary.PutUvarint(buf[:], uint64(len(data)))

	if _, err := dst.Write(buf[:size]); err != nil {
		return errors.Wrap(err, "write data length")
	}

	if _, err := dst.Write(data); err != nil {
		return errors.Wrap(err, "write data")
	}

	return nil
}

// DecodeBinary десериализация данных из источника.
func DecodeBinary(src *bufio.Reader) ([]byte, error) {
	length, err := binary.ReadUvarint(src)
	if err != nil {
		return nil, errors.Wrap(err, "read data length")
	}

	buf := make([]byte, int(length))
	if _, err := io.ReadAtLeast(src, buf, int(length)); err != nil {
		return nil, errors.Wrap(err, "read data")
	}

	return buf, nil
}
