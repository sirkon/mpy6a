package types

import (
	"encoding/binary"
	"fmt"
)

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

// IndexDecodeSafe то же самое что и IndexDecode, но при буфере
// меньше положенного будет возвращён недействительный индекс.
func IndexDecodeSafe(buf []byte) Index {
	if len(buf) < 16 {
		return Index{}
	}

	return IndexDecode(buf)
}

// IndexIncTerm возвращает новый индекс с увеличенным на единицу сроком.
func IndexIncTerm(index Index) Index {
	return Index{
		Term:  index.Term + 1,
		Index: 0,
	}
}

// IndexIncIndex возвращает новый индекс с увеличенным на единицу индексом
// в рамках срока.
func IndexIncIndex(index Index) Index {
	return Index{
		Term:  index.Term,
		Index: index.Index + 1,
	}
}

// IndexLess проверка, что индекс a относится к более раннему периоду чем b.
func IndexLess(a, b Index) bool {
	if a.Term != b.Term {
		return a.Term < b.Term
	}

	return a.Index < b.Index
}

// IndexEqual проверка, что индексы равны.
func IndexEqual(a, b Index) bool {
	return a.Term == b.Term && a.Index == b.Index
}

// IndexLE = IndexLess || IndexEqual.
func IndexLE(a, b Index) bool {
	if a.Term != b.Term {
		return a.Term < b.Term
	}

	return a.Index <= b.Index
}

// IndexCmp сравнение левого и правого индексов.
// Возвращает:
//   * -1 если левый индекс относится к более раннему событию
//   * 0 если индексы относятся к одному событию
//   * 1 если левый индекс относится к более позднему событию
func IndexCmp(a, b Index) int {
	switch {
	case a.Term < b.Term:
		return -1
	case a.Term == b.Term:
		switch {
		case a.Index < b.Index:
			return -1
		case a.Index == b.Index:
			return 0
		default:
			return 1
		}
	default:
		return 1
	}
}

func (id Index) String() string {
	return fmt.Sprintf("%016x", id.Term) + "-" + fmt.Sprintf("%016x", id.Index)
}
