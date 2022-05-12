package state

// SessionData данные сессии для хранения.
type SessionData []byte

// Bytes возвращение бинарных данных сессии
func (s SessionData) Bytes() []byte {
	return s
}

// SavedSessionsData структура данных сохранённых сессий с повтором в заданное время
type SavedSessionsData struct {
	Repeat   uint64
	Sessions []SessionData
}
