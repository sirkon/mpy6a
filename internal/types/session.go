package types

// Session представление сессии.
type Session struct {
	// ID идентификатор сессии, равен индексу состояния в момент её создания.
	// Так же это и "время" её первого изменения.
	ID Index
	// ChangeID идентификатор последнего состояния при котором сессии
	// претерпела изменения.
	ChangeID Index
	// Repeats количество повторов которые успела претерпеть сессия.
	Repeats int32
	// Theme тема сессии.
	Theme int32
	// Data бинарные данные сессии.
	Data []byte
}

// NewSession создание новой сессии.
func NewSession(ID Index, theme int32, data []byte) Session {
	return Session{
		ID:       ID,
		ChangeID: ID,
		Theme:    theme,
		Data:     data,
	}
}
