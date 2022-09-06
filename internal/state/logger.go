package state

import "fmt"

// Logger абстракция логирования со специализацией для работы в рамках системы.
type Logger interface {
	// Error логирование внутренних ошибок. Ошибка может содержать в себе —
	// это выясняется с помощью errors.As — реализацию
	Error(err error)

	// Session возвращает ручку для логирования событий относящихся к сессиям.
	Session(sessionID fmt.Stringer, theme uint32) LoggerSession

	// Cluster возвращает ручку для логирования событий относящееся к кластеру
	Cluster(stateID fmt.Stringer) LoggerCluster
}

// LoggerSession логирование относящееся к сессиям.
type LoggerSession interface {
	// WarningRepeatsLimitReached предупреждение о том, что сессия достигла максимального
	// числа повторов и более не может быть сохранена.
	WarningRepeatsLimitReached(repeatLimit int)
	// WarningNewTooLarge предупреждение, что сессию с таким объёмом первоначальных
	// данных создать нельзя.
	WarningNewTooLarge(attempted, limit int)
	// WarningAppendTooLarge предупреждение, что добавление записи к сессии
	// приведёт к её размеру превышающему ограничение.
	WarningAppendTooLarge(curSize, appendSize, limit int)
	// WarningRewriteTooLarge предупреждение, что новое содержимое сессии слишком
	// большое по размеру.
	WarningRewriteTooLarge(attempted, limit int)

	// DebugNew отладочное логирование при создании новой сессии.
	DebugNew(data []byte)
	// DebugAppend отладочное логирование при добавлении новых данных к сессии
	DebugAppend(data []byte, prevLength int)
	// DebugRewrite отладочное логирование при перезаписи данных сессии.
	DebugRewrite(data []byte, prevLength int)
	// DebugSave отладочное логирование при сохранении сессии данной длины.
	// repeatTime задаётся в секундах, желательно преобразовать это в правильное число.
	DebugSave(length int, repeatAfter uint64)
	// DebugRepeat отладочное логирование при повторе сессии
	DebugRepeat(repeatCount, length int)
}

// LoggerCluster логирование относящееся к кластеру.
type LoggerCluster interface {
}
