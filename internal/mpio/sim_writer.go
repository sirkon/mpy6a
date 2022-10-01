package mpio

import (
	"os"
	"sync"
	"sync/atomic"

	"github.com/sirkon/mpy6a/internal/errors"
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
func NewSimWriter(name string, opts SimWriterOptionsType) (res *SimWriter, err error) {
	res = &SimWriter{
		lock: &sync.RWMutex{},
	}
	opts.apply(res)

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
func (w *SimWriter) Write(p []byte) (n int, err error) {
	w.lock.Lock()
	defer w.lock.Unlock()

	if w.failed.Load() {
		return 0, errInternal{}
	}

	defer func() {
		if err == nil {
			return
		}

		w.failed.Store(true)
	}()

	if len(w.buf)+len(p) > cap(p) {
		if err := w.flush(); err != nil {
			return 0, errors.Wrap(err, "flush buffered data to release buffer")
		}
	}

	if len(p) > cap(w.buf) {
		return 0, errWriteDataOvergrowsBuffer(len(p), cap(w.buf))
	}

	rest := w.buf[len(w.buf):]
	copy(rest[:len(p)], p)
	w.buf = w.buf[:len(w.buf)+len(p)]
	atomic.AddInt64(&w.total, int64(len(p)))
	return len(p), nil
}

// Close закрывает файл после сброса буфера.
func (w *SimWriter) Close() error {
	w.lock.Lock()
	defer w.lock.Unlock()

	if err := w.flush(); err != nil {
		return errors.Wrap(err, "flush buffer")
	}

	if err := w.file.Close(); err != nil {
		return errors.Wrap(err, "close file")
	}

	w.done.Store(true)

	return nil
}

// Size возврат текущего размера файла.
func (w *SimWriter) Size() int64 {
	return w.total
}

func (w *SimWriter) flush() error {
	if len(w.buf) == 0 {
		return nil
	}

	if _, err := w.file.Write(w.buf); err != nil {
		w.failed.Store(true)
		return err
	}

	atomic.AddInt64(&w.size, int64(len(w.buf)))
	w.buf = w.buf[:0]

	return nil
}

func (w *SimWriter) setBufferSize(v int) {
	if v > 0 {
		w.buf = make([]byte, 0, v)
	}
}

func (w *SimWriter) setWritePosition(v uint64) {
	w.total = int64(v)
}

func (w *SimWriter) setLogger(v func(err error)) {
	w.errlog = v
}
