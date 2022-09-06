package ackio

// IsReaderNotReady такая ошибка указывает на то, что на текущий момент
// в источнике данных нет, но они могут появиться при последующих чтениях.
func IsReaderNotReady(err error) bool {
	_, ok := err.(errorReaderNotReady)
	return ok
}

type errorReaderNotReady struct{}

func (errorReaderNotReady) Error() string {
	return "no data is available in underlying reader yet"
}
