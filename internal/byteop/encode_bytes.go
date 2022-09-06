package byteop

import "encoding/binary"

// EncodeBytes кодирует данный слайс байтов src как
// конкатенацию длины src в uvarint и самого src.
func EncodeBytes(dst []byte, src []byte) {
	l := binary.PutUvarint(dst, uint64(len(src)))
	copy(dst[l:], src)
}
