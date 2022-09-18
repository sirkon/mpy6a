package types

import "fmt"

// NewIndex конструктор нового индекса состояния.
func NewIndex(term uint64, index uint64) Index {
	return Index{
		Term:  term,
		Index: index,
	}
}

// Index счётчик состояния.
type Index struct {
	Term  uint64
	Index uint64
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

func (id Index) String() string {
	return fmt.Sprintf("%016x", id.Term) + "-" + fmt.Sprintf("%016x", id.Index)
}