package mpio

// ReadPositionProvider возврат позиции чтения.
type ReadPositionProvider interface {
	PosRead() int64
}

// WritePositionProvider возврат позиции записи.
type WritePositionProvider interface {
	PosWrite() int64
}

// RWPositionProvider возврат позиции и чтения, и записи.
type RWPositionProvider interface {
	ReadPositionProvider
	WritePositionProvider
}
