package state

// RepeatTimeoutDispatcher абстракция для сущностей вычисляющих время повтора сессии
// для данной темы и предоставляющая "известные" и широко используемые таймауты.
type RepeatTimeoutDispatcher interface {
	// Timeout таймаут для сессии из данной темы в секундах.
	Timeout(theme SessionTheme) int
	// FamousTimeouts широко-используемые значения таймаутов.
	FamousTimeouts() []int
}
