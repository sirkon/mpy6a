package mpio

import (
	"io"
	"io/fs"
	"os"
	"sync/atomic"
	"time"

	"github.com/sirkon/mpy6a/internal/errors"
)

// NewSimReader конструктор SimReader.
func NewSimReader(w *SimWriter, opts SimReaderOptionsType) (_ *SimReader, err error) {
	res := &SimReader{
		w: w,
	}
	opts.apply(res)

	file, err := os.Open(w.file.Name())
	if err != nil {
		return nil, errors.Wrap(err, "open source file")
	}

	res.src = file
	var errStep string // При ошибке нужно заполнять эту переменную названием шага на котором она произошла.
	defer func() {
		if err == nil {
			return
		}

		if err := file.Close(); err != nil {
			w.errlog(errors.Wrap(err, "close file after "+errStep))
		}
	}()

	wtotal := atomic.LoadInt64(&w.total)
	switch {
	case res.fpos != 0 && res.fpos < atomic.LoadInt64(&w.size):
		if _, err := file.Seek(res.fpos, 0); err != nil {
			errStep = "seek failure"
			return nil, errors.Wrap(err, "seek to the given read position").
				Int64("invalid-position", res.fpos)
		}
	case res.fpos != 0 && res.fpos <= wtotal:
		res.needseek = true
	case res.fpos != 0:
		errStep = "seek failure"
		return nil, errors.New("the start read position is out of file size").
			Int64("start-read", res.fpos).
			Int64("file-size", wtotal)
	}

	return res, nil
}

// SimReader примитив конкурентного чтения из записываемого источника.
type SimReader struct {
	src *os.File
	w   *SimWriter

	logger   func(err error)
	fpos     int64 // Логическая позиция чтения.
	bpos     int   // Позиция вычитки в буфере.
	needseek bool  // Флаг того, что была сделана вычитка из буфера.
	buf      []byte
}

// Read для реализации io.Reader.
func (r *SimReader) Read(p []byte) (n int, err error) {
	switch r.ensureReadBuffer() {
	case nil:
		n = len(r.buf) - r.bpos
		if n > len(p) {
			n = len(p)
		}
		copy(p, r.buf[r.bpos:r.bpos+n])
		r.bpos += n
		r.fpos += int64(n)
		return n, nil
	case EOD:
		return 0, nil
	case io.EOF:
		return 0, io.EOF
	default:
		return 0, err
	}
}

// ReadByte для реализации io.ByteReader.
// В случае если данных нет, но чтение не законченно
// возвращается ошибка EOD.
func (r *SimReader) ReadByte() (c byte, err error) {
	switch r.ensureReadBuffer() {
	case nil:
		c = r.buf[r.bpos]
		r.bpos++
		r.fpos++
		return c, nil
	case EOD:
		return 0, EOD
	case io.EOF:
		return 0, io.EOF
	default:
		return 0, err
	}
}

// Заполняет буфер если он пуст.
// Возвращает:
//
//  - nil если данные пока есть.
//  - EOD если данных пока нет, но они могут появиться.
//  - io.EOF если данных нет и не будет.
//  - Любая другая ошибка если чтение не удалось.
func (r *SimReader) ensureReadBuffer() error {
	// Если в буфере ещё есть данные, то выходим с успехом
	// сразу же.
	if r.bpos < len(r.buf) {
		return nil
	}

	// В случае если в файле ещё есть данные заполняем
	// буфер из него и выходим.
	wsize := atomic.LoadInt64(&r.w.size)
	if wsize > r.fpos {
		lim := r.getDataSize(wsize)

		if err := r.fillBuffer(lim); err != nil {
			return errors.Wrap(err, "fill buffer")
		}

		return nil
	}

	// Если данных в файле нет, то нужно проверить содержимое
	// буфера записи, там может что-то быть.
	// Вначале проверяем есть ли что-нибудь, если нет то выходим.
	if atomic.LoadInt64(&r.w.total) == r.fpos {
		if r.w.done.Load() {
			return io.EOF
		}

		return EOD
	}

	// Получается, что в буфере есть какие-то данные. Нужно заблокировать
	// запись и перенести их.
	r.w.lock.Lock()

	// Буфер мог быть сброшен в файл, когда мы дожидались захвата лока.
	// Проверяем это.
	if r.w.size > r.fpos {
		lim := r.getDataSize(r.w.size)

		// Освобождаем дорогу записи как можно быстрее, т.к. за ресурсы чтения
		// мы не конкурируем.
		r.w.lock.Unlock()

		if err := r.fillBuffer(lim); err != nil {
			return errors.Wrap(err, "fill buffer with just written data")
		}

		return nil
	}

	// Ну всё, буфер не пуст. Копируем содержимое и выходим.
	d := int(r.w.total - r.fpos)
	start := len(r.w.buf) - d
	if d > cap(r.buf) {
		d = cap(r.buf)
	}
	r.buf = r.buf[:d]
	copy(r.buf, r.w.buf[start:start+d])
	r.buf = r.buf[:d]
	r.bpos = 0
	r.needseek = true
	r.w.lock.Unlock()

	return nil
}

// Close закрытие вычитки.
func (r *SimReader) Close() error {
	if err := r.src.Close(); err != nil {
		return err
	}

	return nil
}

// Stat возвращает статистику аналогично файлам. Только часть её, разумеется.
func (r *SimReader) Stat() (os.FileInfo, error) {
	return simReaderFileInfo{r: r}, nil
}

// Seek перемещает чтение на новую позицию исходного файла.
// Приводит к сбросу буфера.
func (r *SimReader) Seek(offset int64, whence int) (ret int64, err error) {
	total := atomic.LoadInt64(&r.w.total)
	switch whence {
	case 0:
	case 1:
		offset = r.fpos + offset
	case 2:
		offset = total - offset
	default:
		return 0, errors.Newf("unsupported whence value %d", whence)
	}

	if offset < 0 {
		return 0, errors.Newf("invalid final offset %d", offset)
	}
	if offset > total {
		return 0, errors.Newf("final offset is out of range").
			Int64("final-offset", offset).
			Int64("file-size", total)
	}

	r.buf = r.buf[:0]
	r.fpos = offset
	r.needseek = true

	return offset, nil
}

// Pos позиция вычитки из файла.
func (r *SimReader) Pos() int64 {
	return r.fpos
}

func (r *SimReader) fillBuffer(lim int) error {
	if r.needseek {
		r.needseek = false
		if _, err := r.src.Seek(r.fpos, 0); err != nil {
			return errors.Wrap(err, "seek to the read position").Int64("desired-position", r.fpos)
		}
	}

	r.buf = r.buf[:lim]
	n, err := r.src.Read(r.buf)
	if err != nil {
		if err == io.EOF {
			if n > 0 {
				r.buf = r.buf[:n]
				r.bpos = 0
				return nil
			}

			// Это несоответствие между состоянием сущности и файлом:
			// Состояние утверждает что данные в файле есть, но ничего
			// не вычитано.
			err = io.ErrUnexpectedEOF
		}

		return errors.Wrap(err, "read file")
	}

	r.buf = r.buf[:n]
	r.bpos = 0

	return nil
}

// Функция вычисляющая максимальный размер вычитки из источника.
func (r *SimReader) getDataSize(wsize int64) int {
	lim := cap(r.buf)
	if lim > int(wsize-r.fpos) {
		lim = int(wsize - r.fpos)
	}
	return lim
}

func (r *SimReader) setBufferSize(v int) {
	if v > 0 {
		r.buf = make([]byte, 0, v)
	}
}

func (r *SimReader) setReadPosition(v uint64) {
	r.fpos = int64(v)
}

type simReaderFileInfo struct {
	r *SimReader
}

// Name для реализации os.FileInfo
func (s simReaderFileInfo) Name() string {
	return s.r.src.Name()
}

// Size для реализации os.FileInfo
func (s simReaderFileInfo) Size() int64 {
	return s.r.w.total
}

// Mode для реализации os.FileInfo
func (s simReaderFileInfo) Mode() fs.FileMode {
	return 0
}

// ModTime для реализации os.FileInfo
func (s simReaderFileInfo) ModTime() time.Time {
	return time.Now()
}

// IsDir для реализации os.FileInfo
func (s simReaderFileInfo) IsDir() bool {
	return false
}

// Sys для реализации os.FileInfo
func (s simReaderFileInfo) Sys() any {
	return nil
}

var _ os.FileInfo = simReaderFileInfo{}
