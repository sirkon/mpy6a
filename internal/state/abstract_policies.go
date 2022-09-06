package state

// PoliciesProvider поставщик ограничений на объекты системы.
type PoliciesProvider interface {
	// FamousTimeouts список популярных значений задержек повторов.
	FamousTimeouts() []int
	// IsFamousTheme проверка, что данная тема сессий является "известной"
	IsFamousTheme(theme int32) bool
	// Timeout задержка для сессий из данной темы в секундах.
	Timeout(theme int32) int
	// RepeatLimit выдаёт ограничение на количество повторов для
	// сессий из данной темы.
	RepeatLimit(theme int32) int
	// LengthLimit ограничение на длину сессии данной темы
	LengthLimit(theme int32) int
}
