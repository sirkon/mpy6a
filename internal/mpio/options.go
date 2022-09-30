package mpio

// SimWriterOptions опции для SimWriter.
type SimWriterOptions struct {
	BufferSize    int
	WritePosition uint64
	Logger        func(err error)
}

// SimReaderOptions опции для SimReader.
type SimReaderOptions struct {
	BufferSize   int
	ReadPosition uint64
}

// BufReaderOptions опции для BufReader.
type BufReaderOptions struct {
	BufferSize   int
	ReadPosition uint64
}
