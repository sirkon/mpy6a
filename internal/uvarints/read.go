package uvarints

import (
	"encoding/binary"

	"github.com/sirkon/mpy6a/internal/errors"
)

const (
	// ErrorInvalidEncoding ошибка отдаваемая когда закодированное значение явно некорректно.
	ErrorInvalidEncoding errors.Const = "not a correct ULEB 128 encoded uint64"
)

// Read вычитывает кодированное в uvarint значение из буфера.
func Read(buf []byte) (uint64, []byte, error) {
	var x uint64
	var s uint
	for i := range buf {
		if i == binary.MaxVarintLen64 {
			return 0, buf, ErrorInvalidEncoding
		}

		b := buf[i]
		if b < 0x80 {
			if i == binary.MaxVarintLen64-1 && b > 1 {
				return 0, buf, ErrorInvalidEncoding
			}

			return x | uint64(b)<<s, buf[i+1:], nil
		}

		x |= uint64(b&0x7f) << s
		s += 7
	}

	return 0, buf, ErrorInvalidEncoding
}
