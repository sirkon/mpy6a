package types

import "encoding/binary"

// IndexEncode сериализация индекса.
// Внимание: размер буфера не проверяется и в случаем размера меньшего 16 байт
// будет паника.
func IndexEncode(buf []byte, id Index) {
	binary.LittleEndian.PutUint64(buf, id.Term)
	binary.LittleEndian.PutUint64(buf[8:], id.Index)
}

// IndexDecode десериализация индекса.
// Внимание: размер буфера не проверяется и в случаем размера меньшего 16 байт
// будет паника.
func IndexDecode(buf []byte) Index {
	return Index{
		Term:  binary.LittleEndian.Uint64(buf),
		Index: binary.LittleEndian.Uint64(buf[8:]),
	}
}
