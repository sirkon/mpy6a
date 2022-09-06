package mpio

import (
	"sync/atomic"

	"github.com/sirkon/mpy6a/internal/errors"
)

// Write для реализации io.Writer.
// Гарантируется, что переданные в данном вызове данные отправятся
// на диск в рамках одной записи. Т.е. не будет так, что "голова" p
// будет на диске, а "хвост" — в буфере. Либо на диске целиком, либо
// полностью в буфере.
func (s *SimRW) Write(p []byte) (n int, err error) {
	s.wlock.Lock()
	defer s.wlock.Unlock()

	if atomic.LoadInt32(&s.failed) != 0 {
		return 0, errInternal{}
	}

	defer func() {
		if err == nil {
			return
		}

		atomic.StoreInt32(&s.failed, 1)
	}()

	if len(s.wbuf)+len(p) > cap(s.wbuf) {
		if err := s.flush(); err != nil {
			return 0, errors.Wrap(err, "flush buffered data to release buffer")
		}
	}

	if len(p) > cap(s.wbuf) {
		return 0, errWriteDataOvergrowsBuffer(len(p), cap(s.wbuf))
	}

	rest := s.wbuf[len(s.wbuf):]
	copy(rest[:len(p)], p)
	s.wbuf = s.wbuf[:len(s.wbuf)+len(p)]
	atomic.AddInt64(&s.wtotal, int64(len(p)))
	return len(p), nil
}
