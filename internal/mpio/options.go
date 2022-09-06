package mpio

// ReadOptionsReceiver приёмник для опций чтения.
type ReadOptionsReceiver interface {
	setBufferSize(n int)
	setReadPosition(pos int64)
}

// ReadLimitedOptionsReceiver приёмник для опции ограничения области чтения сверху.
type ReadLimitedOptionsReceiver interface {
	setReadLimitPosition(lim int64)
}

// WriteOptionsReceiver приёмник для опция записи.
type WriteOptionsReceiver interface {
	setWritePosition(pos int64)
	setFsyncOn()
}

// ErrorLoggerReceiver приёмник для опции установки логирования.
type ErrorLoggerReceiver interface {
	setErrorLogger(func(err error))
}

// Option определение опции.
type Option[T any] func(r T, _ prohibitCustomOpts)

type prohibitCustomOpts struct{}

// WithBufferSize установка буфера.
func WithBufferSize[T ReadOptionsReceiver](n int) Option[T] {
	return func(r T, _ prohibitCustomOpts) {
		r.setBufferSize(n)
	}
}

// WithReadPosition установка логической позиции чтения.
func WithReadPosition[T ReadOptionsReceiver](pos int64) Option[T] {
	return func(r T, _ prohibitCustomOpts) {
		r.setReadPosition(pos)
	}
}

// WithReadLimit установка ограничения на область чтения.
func WithReadLimit[T ReadLimitedOptionsReceiver](lim int64) Option[T] {
	return func(r T, _ prohibitCustomOpts) {
		r.setReadLimitPosition(lim)
	}
}

// WithWritePosition установка начальной позиции записи.
func WithWritePosition[T WriteOptionsReceiver](pos int64) Option[T] {
	return func(w T, _ prohibitCustomOpts) {
		w.setWritePosition(pos)
	}
}

// WithFsync установка необходимости проведения fsync при сбросе данных на диск.
func WithFsync[T WriteOptionsReceiver]() Option[T] {
	return func(w T, _ prohibitCustomOpts) {
		w.setFsyncOn()
	}
}

// WithErrorLogger установка логирования.
func WithErrorLogger[T ErrorLoggerReceiver](logger func(error)) Option[T] {
	return func(l T, _ prohibitCustomOpts) {
		l.setErrorLogger(logger)
	}
}
