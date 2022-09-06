package logging

// Logger абстракция предназначенная для логирования в строго определённых ситуациях.
// Реализация логирования должна делаться пользователями библиотеки.
type Logger interface {
	SnapshotLogFailedToInit(logFileName string, err error)
	SnapshotLogFailedToAppend(err error)
	SnapshotLogFailedToRotate(err error)
}
