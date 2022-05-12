package state

// Operation операции лога.
type Operation interface {
	isLogOperation()
}
