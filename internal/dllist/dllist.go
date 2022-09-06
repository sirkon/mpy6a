package dllist

// New конструктор пустого двусвязного списка.
func New[T any]() *DLList[T] {
	return &DLList[T]{}
}

// DLList пустая дву.
// WARNING: Не предоставляет гарантий безопасности при многопоточном доступе.
type DLList[T any] struct {
	first *Node[T]
	last  *Node[T]
}

// Push добавление нового значения в конец списка с возвратом созданного узла.
func (l *DLList[T]) Push(v T) *Node[T] {
	n := &Node[T]{
		next:  nil,
		prev:  l.last,
		value: v,
	}

	if l.first == nil {
		l.first = n
		l.last = n
		return n
	}

	l.last.next = n
	l.last = n

	return n
}

// DeleteFirst удаление первого элемента списка.
func (l *DLList[T]) DeleteFirst() {
	if l.first == nil {
		return
	}

	f := l.first
	l.first = f.next
	if f.next == nil {
		// в списке был только один элемент
		l.last = nil
	} else {
		f.next.prev = nil
	}

	f.next = nil // для упрощения работы GC
}

// First получение первого элемента списка.
func (l *DLList[T]) First() *Node[T] {
	return l.first
}

// Delete удаление данного узла из списка.
func (l *DLList[T]) Delete(n *Node[T]) {
	if n.prev != nil {
		n.prev.next = n.next
	}

	if n.next != nil {
		n.next.prev = n.prev
	}

	if l.first == n {
		l.first = n.next
	}

	if l.last == n {
		l.last = n.prev
	}

	n.cleanup()
}
