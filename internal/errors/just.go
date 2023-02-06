package errors

// Just возвращает ошибку с таким же текстом, что и данная err,
// в то же время давая возможность добавить структурированный контекст.
// То же самое, что и Wrap с пустым текстовым аргументом.
func Just(err error) *Error {
	return &Error{
		msg:       "",
		err:       err,
		ctxPrefix: "",
	}
}
