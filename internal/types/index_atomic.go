package types

import "unsafe"

// IndexAtomic индекс для атомарной работы.
// Экземпляр этого типа должен создаваться
// исключительно с использованием конструктора
// NewIndexAtomic.
type IndexAtomic struct {
	data []byte
}

// NewIndexAtomic создание нового атомарного индекса.
func NewIndexAtomic() IndexAtomic {
	return newIndexAtomic()
}

// Set атомарная установка индекса в заданное значение.
func (id *IndexAtomic) Set(index Index) {
	setIndexAtomic(uintptr(unsafe.Pointer(&id.data[0])), index.Term, index.Index)
}

// Get атомарное получение индекса.
func (id *IndexAtomic) Get() Index {
	term, index := getIndexAtomic(uintptr(unsafe.Pointer(&id.data[0])))
	return Index{
		Term:  term,
		Index: index,
	}
}

func setIndexAtomic(ptr uintptr, term, index uint64)

func getIndexAtomic(ptr uintptr) (uint64, uint64)

const indexAtomicSize = 16

// Создание нового атомарного индекса оперирующего
// с областью памяти имеющей требуемое смещение адреса.
// Величина смещения должна быть степенью двойки.
func newIndexAtomicAlign(align int) IndexAtomic {
	data := make([]byte, align+indexAtomicSize)
	v := uintptr(unsafe.Pointer(&data[0]))

	off := v & (uintptr(align) - 1)
	if off != 0 {
		data = data[uintptr(align)-off:]
	}

	return IndexAtomic{
		data: data[:indexAtomicSize],
	}
}
