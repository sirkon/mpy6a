package types

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
