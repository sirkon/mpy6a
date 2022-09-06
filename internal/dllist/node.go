package dllist

// Node узел содержащий данное значение в связанном списке.
type Node[T any] struct {
	prev *Node[T]
	next *Node[T]

	value T
}

// Value возврат значения лежащего в узле.
func (n *Node[T]) Value() T {
	return n.value
}

func (n *Node[T]) cleanup() {
	n.prev = nil
	n.next = nil
}
