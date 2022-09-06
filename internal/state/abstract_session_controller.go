package state

// SessionController абстракция управления активной сессией.
type SessionController interface {
	// Append добавить новую запись в сессию
	Append(data []byte) error
}
