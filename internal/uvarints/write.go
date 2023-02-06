package uvarints

import (
	"encoding/binary"
	"io"
)

// Write кодирование числа в ULEB128 и запись в буфер.
// Возвращается длина записанных данных.
func Write(dst io.Writer, v uint64) (n int, err error) {
	var buf [16]byte
	l := binary.PutUvarint(buf[:], v)
	if _, err := dst.Write(buf[:l]); err != nil {
		return 0, err
	}

	return l, nil
}
