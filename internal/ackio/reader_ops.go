package ackio

// ReaderOpt определение опции чтения.
type ReaderOpt func(r *Reader, _ readerOptRestriction)

type readerOptRestriction struct{}

// WithFrameSize устанавливает максимальный размер кадра.
// Предполагается, что он должен быть не меньше чем максимальный
// размер сессии, но не намного.
func WithFrameSize(frame int) ReaderOpt {
	return func(r *Reader, _ readerOptRestriction) {
		r.frm = frame
	}
}

// WithReaderBufferSize устанавливает начальный размер буфера
// в читателе.
func WithReaderBufferSize(size int) ReaderOpt {
	return func(r *Reader, _ readerOptRestriction) {
		r.buf = make([]byte, size)
	}
}

// WithReaderSourcePosition установка логической позиции чтения
// в источнике. Она равна 0 по-умолчанию.
func WithReaderSourcePosition(pos uint64) ReaderOpt {
	return func(r *Reader, _ readerOptRestriction) {
		r.pos = int64(pos)
	}
}
