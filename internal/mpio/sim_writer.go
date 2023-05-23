package mpio

import (
	"os"
	"sync"
	"sync/atomic"

	"github.com/sirkon/mpy6a/internal/errors"
)

// SimWriter примитив позволяющий конкурентно осуществлять
// чтение и запись с одним файлом.
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

// NewSimWriterFile альтернативный конструктор с использованием готового файлового объекта.
// Необходимо ручное задание позиции. Позиция заданная через опцию игнорируется.
func NewSimWriterFile(file *os.File, pos uint64, opts SimWriterOptionsType) *SimWriter {
	res := &SimWriter{
		file: file,
		lock: &sync.RWMutex{},
	}
	opts.apply(res)
	res.size = int64(pos)
	res.total = int64(pos)

	return res
}

// Write запись данных.
// Гарантируется, что переданные в данном вызове данные отправятся
// на диск в рамках одной записи. Т.е. не будет так, что "голова" p
// будет на диске, а "хвост" — в буфере. Либо на диске целиком, либо
// полностью в буфере.
func (w *SimWriter) Write(p []byte) (n int, err error) {
	w.lock.Lock()
	defer w.lock.Unlock()

	if len(p) > cap(w.buf) {
		return 0, errWriteDataOvergrowsBuffer(len(p), cap(w.buf))
	}

	if w.failed.Load() {
		return 0, errInternal{}
	}

	defer func() {
		if err == nil {
			return
		}

		w.failed.Store(true)
	}()

	if len(w.buf)+len(p) > cap(w.buf) {
		if err := w.flush(); err != nil {
			return 0, errors.Wrap(err, "flush buffered data to release buffer")
		}
	}

	rest := w.buf[len(w.buf):]
	copy(rest[:len(p)], p)
	w.buf = w.buf[:len(w.buf)+len(p)]
	atomic.AddInt64(&w.total, int64(len(p)))
	return len(p), nil
}

// WriteFA запись данных с гарантиями целостности аналогичными Write.
// Возвращает флаг того, был ли сделан сброс буфера при записи.
func (w *SimWriter) WriteFA(p []byte) (flushed bool, err error) {
	w.lock.Lock()
	defer w.lock.Unlock()

	if len(p) > cap(w.buf) {
		return false, errWriteDataOvergrowsBuffer(len(p), cap(w.buf))
	}

	if w.failed.Load() {
		return false, errInternal{}
	}

	if len(w.buf)+len(p) > cap(w.buf) {
		if err := w.flush(); err != nil {
			return false, errors.Wrap(err, "flush buffered data to release buffer")
		}

		flushed = true
	}

	rest := w.buf[len(w.buf):]
	copy(rest[:len(p)], p)
	w.buf = w.buf[:len(w.buf)+len(p)]
	atomic.AddInt64(&w.total, int64(len(p)))
	return flushed, nil
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

// Flush принудительный сброс буферизованных данных на диск.
func (w *SimWriter) Flush() error {
	w.lock.Lock()
	defer w.lock.Unlock()

	return w.flush()
}

// Name возврат имени файла.
func (w *SimWriter) Name() string {
	return w.file.Name()
}

// Size возврат текущего размера файла.
func (w *SimWriter) Size() int64 {
	return w.total
}

// Lock для реализации sync.Locker.
func (w *SimWriter) Lock() {
	w.lock.Lock()
}

// Unlock для реализации sync.Locker.
func (w *SimWriter) Unlock() {
	w.lock.Unlock()
}

// Buf возвращает текущий буфер.
func (w *SimWriter) Buf() []byte {
	return w.buf
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
	w.size = int64(v)
	w.total = int64(v)
}

func (w *SimWriter) setLogger(v func(err error)) {
	w.errlog = v
}

// EnsureBufferSpace попытка высвободить достаточно места
// в буфере для записи длиной n. Может возвратить ошибку
// слишком короткого буфера или ошибку сброса данных на диск.
func EnsureBufferSpace(w *SimWriter, n int) error {
	if n+len(w.buf) < cap(w.buf) {
		return nil
	}

	if n > cap(w.buf) {
		return errWriteDataOvergrowsBuffer(n, cap(w.buf))
	}

	if err := w.Flush(); err != nil {
		return errors.Wrap(err, "flush previously collected data")
	}

	return nil
}
