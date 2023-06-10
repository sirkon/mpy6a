package mpio

import "io"

// DataWriter объявление писалки для записи данных при кодировании.
type DataWriter interface {
	io.Writer
	io.ByteWriter
}

// DataReader объявление читалки для восстановления кодированных данных.
type DataReader interface {
	io.Reader
	io.ByteReader
}
