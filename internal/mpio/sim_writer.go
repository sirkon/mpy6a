package mpio

import (
	"log"
	"os"
	"sync"
	"sync/atomic"

	"github.com/sirkon/mpy6a/internal/errors"
)

const (
	defaultBufferSize = 4096
)

// SimWriter примитив для записи в файл.
type SimWriter struct {
	file *os.File
	lock *sync.RWMutex

	failed atomic.Bool
	done   atomic.Bool

	size  int64 // Текущее количество байт скинутых из буфера в файл.
	total int64 // Общее количество байт в файле и в буфере.
	buf   []byte

	errlog func(err error)
}

// NewSimWriter конструктор SimWriter.
func NewSimWriter(name string, opts SimWriterOptions) (res *SimWriter, err error) {
	res = &SimWriter{}
	if opts.BufferSize < 0 {
		return nil, errors.New("buffer size must not be negative").
			Int("invalid-buffer-size", opts.BufferSize)
	}

	res.errlog = opts.Logger
	if res.errlog == nil {
		res.errlog = func(err error) {
			log.Println(err)
		}
	}

	if opts.BufferSize == 0 {
		opts.BufferSize = defaultBufferSize
	}
	res.buf = make([]byte, 0, opts.BufferSize)

	res.lock = &sync.RWMutex{}

	file, err := os.OpenFile(name, os.O_WRONLY|os.O_CREATE, 0644)
	if err != nil {
		return nil, errors.Wrap(err, "open file")
	}

	var errStep string
	defer func() {
		if err == nil {
			return
		}

		if err := file.Close(); err != nil {
			res.errlog(errors.Wrap(err, "close file after "+errStep))
		}
	}()

	res.total = int64(opts.WritePosition)
	if res.total != 0 {
		if _, err := file.Seek(res.total, 0); err != nil {
			errStep = "seek failure"
			return nil, errors.Wrap(err, "seek write to position").Int64("desired-position", res.total)
		}
	}
	res.file = file

	return res, nil
}

// Write запись данных.
// Гарантируется, что переданные в данном вызове данные отправятся
// на диск в рамках одной записи. Т.е. не будет так, что "голова" p
// будет на диске, а "хвост" — в буфере. Либо на диске целиком, либо
// полностью в буфере.
func (s *SimWriter) Write(p []byte) (n int, err error) {
	s.lock.Lock()
	defer s.lock.Unlock()

	if s.failed.Load() {
		return 0, errInternal{}
	}

	defer func() {
		if err == nil {
			return
		}

		s.failed.Store(true)
	}()

	if len(s.buf)+len(p) > cap(p) {
		if err := s.flush(); err != nil {
			return 0, errors.Wrap(err, "flush buffered data to release buffer")
		}
	}

	if len(p) > cap(p) {
		return 0, errWriteDataOvergrowsBuffer(len(p), cap(s.buf))
	}

	rest := s.buf[len(s.buf):]
	copy(rest[:len(p)], p)
	s.buf = s.buf[:len(s.buf)+len(p)]
	s.total += int64(len(p))
	return len(p), nil
}

// Close закрывает файл после сброса буфера.
func (s *SimWriter) Close() error {
	s.lock.Lock()
	defer s.lock.Unlock()

	if err := s.flush(); err != nil {
		return errors.Wrap(err, "flush buffer")
	}

	if err := s.file.Close(); err != nil {
		return errors.Wrap(err, "close file")
	}

	s.done.Store(true)

	return nil
}

// Size возврат текущего размера файла.
func (s *SimWriter) Size() int64 {
	return s.total
}

func (s *SimWriter) flush() error {
	if len(s.buf) == 0 {
		return nil
	}

	if _, err := s.file.Write(s.buf); err != nil {
		s.failed.Store(true)
		return err
	}

	atomic.AddInt64(&s.size, int64(len(s.buf)))
	s.buf = s.buf[:0]

	return nil
}
