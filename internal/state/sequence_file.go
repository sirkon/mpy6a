package state

import (
	"encoding/binary"
	"io"
	"os"
	"sync"
	"sync/atomic"

	"github.com/sirkon/errors"
)

const (
	// ErrorFileIsInFailedState ошибка отдаваемая если файл находится в ошибочном состоянии
	ErrorFileIsInFailedState errors.Const = "file is in failed state"
	// ErrorFileSessionLengthOverflow ошибка отдаваемая когда длина сессии явно некорректна
	ErrorFileSessionLengthOverflow errors.Const = "session length overflow"
)

// SequenceFile обвязка файла предоставляющая возможность конкурентной
// буферизованной записи и чтения сессий из одного буфера.
type SequenceFile struct {
	wfile *os.File
	rfile *os.File

	lock   *sync.Mutex
	failed int32

	// буфер на запись
	wsize  uint64 // Размер файла (виртуальный), реальный может быть больше.
	wtotal uint64 // Полный размер файла записи, включая данные в буфере.
	wbuf   []byte
	wdone  int32

	// буфер на чтение
	rfpos    uint64 // Позиция чтения в файле.
	rbpos    int    // Позиция чтения в буфере.
	needseek bool   // Было чтение из буфера записи, требуется перепозиционирования для чтения из файла.
	rbuf     []byte
	drbuf    []byte // Дублирующий буфер.
}

// NewSequenceFile конструктор объекта конкурентного чтения и записи из файла.
func NewSequenceFile(
	wfile, rfile *os.File,
	wpos, rpos, maxSessionSize uint64,
) (*SequenceFile, error) {
	var wdone int32 = 1
	if wfile != nil {
		if _, err := wfile.Seek(int64(wpos), 0); err != nil {
			return nil, errors.Wrap(err, "seek to the latest commited write position")
		}
		wdone = 0
	}

	if _, err := rfile.Seek(int64(rpos), 0); err != nil {
		return nil, errors.Wrap(err, "seek to the latest commited read position")
	}

	res := &SequenceFile{
		wfile:  wfile,
		wdone:  wdone,
		rfile:  rfile,
		lock:   &sync.Mutex{},
		wsize:  wpos,
		wtotal: wpos,
		rfpos:  rpos,
		wbuf:   make([]byte, 0, int(maxSessionSize)*3+48),
		rbuf:   make([]byte, 0, int(maxSessionSize)*3+96),
		drbuf:  make([]byte, 0, int(maxSessionSize)*3+96),
	}

	return res, nil
}

// CloseWrite завершение записи.
func (f *SequenceFile) CloseWrite() error {
	if f.wdone > 0 {
		return nil
	}

	if err := f.flush(); err != nil {
		return errors.Wrap(err, "flush buffered data")
	}

	if err := f.wfile.Close(); err != nil {
		return errors.Wrap(err, "close writ file")
	}

	f.wdone = 1
	return nil
}

// CloseRead завершение чтения.
func (f *SequenceFile) CloseRead() error {
	if err := f.rfile.Close(); err != nil {
		return errors.Wrap(err, "close read file")
	}

	return nil
}

// CloseAll полное закрытие всего.
func (f *SequenceFile) CloseAll() error {
	if err := f.CloseWrite(); err != nil {
		return errors.Wrap(err, "close writer")
	}

	if err := f.CloseRead(); err != nil {
		return errors.Wrap(err, "close sequenceReader")
	}

	return nil
}

// Flush сброс накопленных на буфер данных в файл.
func (f *SequenceFile) Flush() (err error) {
	f.lock.Lock()

	if err := f.checkWriteState(); err != nil {
		f.lock.Unlock()
		return errors.Wrap(err, "check write state")
	}

	defer func() {
		f.handleError(err)
		f.lock.Unlock()
	}()

	if err := f.flush(); err != nil {
		return err
	}

	f.wtotal += uint64(len(f.wbuf))

	return nil
}

// ReadSession чтение сессии.
// Возвращаемые значения трактуются следующим образом:
// 1. (session != nil, nil) — успешная вычитка очередной сессии.
// 2. (nil, nil) — новых данных нет, но файл ещё пишется
// 3. (nil, io.EOF) — файл уже не пишется и новых данных в нём нет.
// 4. (nil, err != io.EOF) — ошибка при вычитке.
func (f *SequenceFile) ReadSession() (session []byte, err error) {
	defer func() {
		f.handleError(err)
	}()

	if err := f.checkReadState(); err != nil {
		return nil, errors.Wrap(err, "check read state")
	}

	var r sequenceReader
	f.snapReader(&r)

	defer func() {
		if err != nil {
			f.needseek = true // Могла быть вычитка, нужно вернуть на предыдущую позицию.
			return
		}

		f.unsnapReader(&r)
	}()

	for {
		// Что-то есть в буфере, начинаем читать данные следующей сессии
		// из него. Возможно, при этом ещё придётся обращаться к файлу.
		if r.bpos < len(r.buf) {
			return r.readFromBuffer()
		}

		// В буфере ничего не оказалось, поэтому заполняем его снова.
		// Либо из файла, либо из буфера писателя.
		r.buf = r.buf[:0]
		r.bpos = 0

		// Если файл до конца не дочитан, читаем из него.
		f.lock.Lock()
		r.wsize = f.wsize
		f.lock.Unlock()

		if r.fpos < r.wsize {
			if err := r.readFromFile(); err != nil {
				return nil, errors.Wrap(err, "read to fill buffer")
			}

			continue
		}

		// В файле ничего нет, нужно смотреть в буфер
		f.lock.Lock()

		// Но если за прошедшее время что-то успели записать,
		// то повторяем чтение.
		if r.fpos < r.wsize {
			f.lock.Unlock()
			if err := r.readFromFile(); err != nil {
				return nil, errors.Wrap(err, "read to fill buffer after it grew at once")
			}

			continue
		}

		// Быть может, мы высосали всё; здесь два случая:
		// если файл больше не пишется, то это и финал чтения,
		// а иначе просто отсутствие новых данных.
		if r.fpos == f.wtotal {
			wdone := f.wdone > 0
			f.lock.Unlock()
			if wdone {
				return nil, io.EOF
			}

			return nil, nil
		}

		// Есть новые данные в буфере, копируем их.
		r.needseek = true
		off := uint64(len(f.wbuf)) - f.wtotal + r.fpos
		r.buf = r.buf[:f.wtotal-r.fpos]
		r.fpos = f.wtotal
		copy(r.buf, f.wbuf[off:len(f.wbuf)])
		f.lock.Unlock()

		// В буфере что-то есть, повторяем.
	}
}

// WriteSession запись сессии.
func (f *SequenceFile) WriteSession(session []byte) (err error) {
	if err := f.checkWriteState(); err != nil {
		return errors.Wrap(err, "check write state")
	}

	f.lock.Lock()
	defer func() {
		f.handleError(err)
		f.lock.Unlock()
	}()

	var sesslen []byte
	{
		var sesslenbuf [16]byte
		sesslenbuflen := binary.PutUvarint(sesslenbuf[:16], uint64(len(session)))
		sesslen = sesslenbuf[:sesslenbuflen]
	}

	// Смотрим, полезет ли сессия в оставшееся место в буфере.
	if len(f.wbuf)+len(sesslen)+len(session) <= cap(f.wbuf) {
		f.writeToBuf(sesslen, session)

		return nil
	}

	if err := f.flush(); err != nil {
		return errors.Wrap(err, "flush")
	}

	f.writeToBuf(sesslen, session)
	return nil
}

func (f *SequenceFile) writeToBuf(sesslen, session []byte) {
	prevlen := len(f.wbuf)
	f.wbuf = f.wbuf[:prevlen+len(sesslen)+len(session)]
	buf := f.wbuf[prevlen:]

	copy(buf, sesslen)
	copy(buf[len(sesslen):], session)

	f.wtotal += uint64(len(sesslen) + len(session))
}

func (f *SequenceFile) snapReader(r *sequenceReader) {
	r.file = f.rfile
	r.needseek = f.needseek
	r.fpos = f.rfpos
	r.bpos = f.rbpos
	r.buf = f.rbuf
	r.dbuf = f.drbuf

	r.wsize = f.wsize
}

func (f *SequenceFile) unsnapReader(r *sequenceReader) {
	f.needseek = r.needseek
	f.rfpos = r.fpos
	f.rbpos = r.bpos
	f.rbuf = r.buf
	f.drbuf = r.dbuf
}

func (f *SequenceFile) checkWriteState() error {
	if atomic.LoadInt32(&f.failed) != 0 {
		return ErrorFileIsInFailedState
	}

	if atomic.LoadInt32(&f.wdone) != 0 {
		return ErrorFileIsInFailedState
	}

	return nil
}

func (f *SequenceFile) checkReadState() error {
	if atomic.LoadInt32(&f.failed) != 0 {
		return ErrorFileIsInFailedState
	}

	return nil
}

func (f *SequenceFile) handleError(err error) {
	if err == nil {
		return
	}

	atomic.StoreInt32(&f.failed, 1)
}

func (f *SequenceFile) flush() error {
	if len(f.wbuf) == 0 {
		return nil
	}

	if _, err := f.wfile.Write(f.wbuf); err != nil {
		return errors.Wrap(err, "write buffered data")
	}

	f.wsize += uint64(len(f.wbuf))
	f.wbuf = f.wbuf[:0]

	return nil
}

type sequenceReader struct {
	file     *os.File
	needseek bool
	fpos     uint64
	bpos     int
	buf      []byte
	dbuf     []byte

	wsize uint64
}

func (r *sequenceReader) readFromBuffer() (session []byte, err error) {
	var sesslen uint64
	for {
		sesslen, err = r.readUvarint()
		switch err {
		case io.EOF:
			// Данных не хватает, надо подсосать.
			// Заметим, что недостаток байт в сессии может случится
			// исключительно в ситуации когда она читалась из файла,
			// Потому что WriteSession всегда делится только полными сессиями.
			// Поэтому дочитываем данные из файла. При этом перемещаем
			// данные в другой буфер, начиная с непрочитанного ещё
			// куска, чтобы гарантированно иметь пространство для хранения
			// сессии в остатках.
			r.readBufferSwap()
			if err := r.readFromFile(); err != nil {
				return nil, errors.Wrap(err, "read missing session length data")
			}
			continue
		case ErrorFileSessionLengthOverflow:
			// Что-то вообще несообразное в буфере, это фатальная ошибка.
			return nil, errors.Wrapf(
				err,
				"read session length in %s from position %d",
				r.file.Name(),
				r.fpos+uint64(r.bpos),
			)
		}

		break
	}

	// Если данных в сессии не хватает, то их нужно дочитать.
	// Опять, данная ситуация может случиться исключительно в случае
	// если источником данных выступает файл. Причём если
	// до этого выше не хватило данных для длины, то в дочитанных
	// данных будет лежать и сессия, то есть внутрь if-а мы в этом
	// случае не попадаем.
	if uint64(len(r.buf)-r.bpos) < sesslen {
		r.readBufferSwap()
		if err := r.readFromFile(); err != nil {
			return nil, errors.Wrap(err, "read missing session data")
		}
	}

	// В этой точке в буфере есть полные данные следующей сессии, ура!
	session = r.buf[r.bpos : uint64(r.bpos)+sesslen]
	r.bpos += int(sesslen)

	return session, nil
}

func (r *sequenceReader) readUvarint() (uint64, error) {
	var x uint64
	var s uint
	for i := 0; i < binary.MaxVarintLen64; i++ {
		if i == len(r.buf) {
			return 0, io.EOF
		}
		b := r.buf[r.bpos+i]
		if b < 0x80 {
			if i == binary.MaxVarintLen64-1 && b > 1 {
				return 0, ErrorFileSessionLengthOverflow
			}

			r.bpos += i + 1
			return x | uint64(b)<<s, nil
		}
		x |= uint64(b&0x7f) << s
		s += 7
	}

	return 0, ErrorFileSessionLengthOverflow
}

func (r *sequenceReader) readBufferSwap() {
	r.buf, r.dbuf = r.dbuf, r.buf
	r.buf = r.buf[:len(r.dbuf)-r.bpos]
	copy(r.buf, r.dbuf[r.bpos:len(r.dbuf)])
	r.bpos = 0
}

func (r *sequenceReader) readFromFile() error {
	if r.needseek {
		if _, err := r.file.Seek(int64(r.fpos), 0); err != nil {
			return errors.Wrap(err, "seek to the read position")
		}

		r.needseek = false
	}

	// Сейчас будем читать. Но с одним условием:
	// Могла быть неудачная запись скинувшая только часть данных
	// Поэтому читать надо вплоть до wsize, не больше.
	limit := r.fpos + uint64(cap(r.buf)) - uint64(len(r.buf))
	if limit > r.wsize {
		limit = r.wsize
	}
	buf := r.buf[len(r.buf) : len(r.buf)+int(limit-r.fpos)]

	read, err := r.file.Read(buf)
	if err != nil {
		if err == io.EOF {
			return nil
		}

		return errors.Wrap(err, "read from file")
	}

	r.buf = r.buf[:len(r.buf)+read]
	r.fpos += uint64(read)
	return nil
}
