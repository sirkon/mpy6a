package types

import "unsafe"

const bits128 = 16

// Отдаёт буфер данных который может быть использован
// для проведения атомарных операций.
//
// Величина align должна быть степенью двойки, т.е.
// 1, 2, 4, 8 и т.д.
func newBufferAtomic128() []byte {
	data := make([]byte, atomic128align+bits128)
	v := uintptr(unsafe.Pointer(&data[0]))

	off := v & (uintptr(atomic128align) - 1)
	data = data[uintptr(atomic128align)-off:]
	return data[:bits128]
}

func setAtomic(ptr uintptr, term, index uint64)

func getAtomic(ptr uintptr) (uint64, uint64)
