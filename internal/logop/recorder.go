package logop

import "sync"

// Recorder сериализация данных операций.
type Recorder struct {
	buf  []byte
	bufs [][]byte

	// Заняты все буфера между low включая low и не доходя до hig.
	// Если low = hig, то буфера не заняты.
	low int
	hig int

	lock *sync.Mutex
}

func (r *Recorder) allocateBuffer(n int) []byte {
	return make([]byte, 0, n)
}
