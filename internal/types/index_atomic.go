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
	return IndexAtomic{
		data: newBufferAtomic128(),
	}
}

// Set атомарная установка индекса в заданное значение.
func (id IndexAtomic) Set(index Index) {
	setAtomic(uintptr(unsafe.Pointer(&id.data[0])), index.Term, index.Index)
}

// Get атомарное получение индекса.
func (id IndexAtomic) Get() Index {
	term, index := getAtomic(uintptr(unsafe.Pointer(&id.data[0])))
	return Index{
		Term:  term,
		Index: index,
	}
}
