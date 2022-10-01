package options

// BufReaderBufferSize задаёт размер буфера при вычитке.
const BufReaderBufferSize int = 4096

// BufReaderReadPosition задаёт начальную логическую позицию чтения из источника.
// WARNING это логическая позиция, а не физическая. Физическое смещение в источнике
//         должен задавать сам пользователь библиотеки.
var BufReaderReadPosition uint64

// BufReaderReadLimit задание конечной логической позиции чтения из источника.
var BufReaderReadLimit uint64
