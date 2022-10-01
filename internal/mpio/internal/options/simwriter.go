package options

import "log"

// SimWriterBufferSize задание длины буфера записи. Длина по умолчанию – 4096 байт.
const SimWriterBufferSize int = 4096

// SimWriterWritePosition задание начальной позиции записи в приёмник.
var SimWriterWritePosition uint64

// SimWriterLogger задание логгера ошибок.
func SimWriterLogger(err error) {
	log.Println(err)
}
