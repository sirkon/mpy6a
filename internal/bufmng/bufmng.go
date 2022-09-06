package bufmng

// New конструктор управления буфером
func New() *BufferManager {
	return &BufferManager{}
}

// BufferManager управление буфером
type BufferManager struct {
	buf []byte
}

// Get выдать буфер нужного размера
func (b *BufferManager) Get(n int) []byte {
	if cap(b.buf) >= n {
		return b.buf[:n]
	}

	b.buf = make([]byte, n)
	return b.buf
}
