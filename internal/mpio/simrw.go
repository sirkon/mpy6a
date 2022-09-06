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

// SimRW примитив для одновременного чтения и записи из файла.
// При этом предполагается, что конкурентность есть только
// между чтением и записью, но при этом и чтение отдельно,
// и запись отдельно осуществляются строго последовательно.
type SimRW struct {
	wfile *os.File
	rfile *os.File

	wlock  *sync.Mutex
	failed int32

	// Буфер записи.
	wsize     int64 // Текущее число байт записанное непосредственно в файл.
	wtotal    int64 // Общее количество байт в файле и в буфере.
	wbuf      []byte
	wdone     int32
	needFsync bool // TODO нужно заподдержать однажды.

	// Буфер чтения.
	rfpos    int64 // Логическая позиция чтения.
	rbpos    int   // Позиция вычитки в буфере.
	needseek bool  // Флаг того, что была сделана вычитка из буфера.
	rbuf     []byte

	errlog func(err error)
}

// NewSimRW конструктор сущности SimRW.
func NewSimRW(name string, opts ...Option[*SimRW]) (res *SimRW, err error) {
	res = &SimRW{}
	for _, opt := range opts {
		opt(res, prohibitCustomOpts{})
	}
	if res.errlog == nil {
		res.errlog = func(err error) {
			log.Println(err)
		}
	}
	if len(res.rbuf) == 0 {
		res.setBufferSize(defaultBufferSize)
	}
	res.wlock = &sync.Mutex{}

	// Обработка файла для записи.
	wfile, err := os.OpenFile(name, os.O_WRONLY|os.O_CREATE, 0644)
	if err != nil {
		return nil, errors.Wrap(err, "open file for writing")
	}
	defer func() {
		// Если происходит ошибка, то файл нужно закрыть.
		if err == nil {
			return
		}

		if err := wfile.Close(); err != nil {
			res.errlog(errors.Wrap(err, "close write file after an error"))
		}
	}()
	if res.wtotal != 0 {
		if _, err := wfile.Seek(res.wtotal, 0); err != nil {
			return nil, errors.Wrapf(err, "seek write to position").
				Int64("desired-position", res.rfpos)
		}
	}
	res.wfile = wfile

	// Обрабатываем файл для чтения.
	rfile, err := os.Open(name)
	if err != nil {
		return nil, errors.Wrap(err, "open file for reading")
	}
	defer func() {
		// Так же, закрываем при ошибке.
		if err == nil {
			return
		}

		if err := rfile.Close(); err != nil {
			res.errlog(errors.Wrap(err, "cloose read file after an error"))
		}
	}()
	if res.rfpos != 0 {
		if _, err := rfile.Seek(res.rfpos, 0); err != nil {
			return nil, errors.Wrapf(err, "seek read to position").
				Int64("desired-position", res.rfpos)
		}
	}
	res.rfile = rfile

	return res, nil
}

// CloseWrite завершение записи.
func (s *SimRW) CloseWrite() error {
	s.wlock.Lock()
	defer s.wlock.Unlock()

	if err := s.flush(); err != nil {
		return errors.Wrap(err, "flush the rest of write buffer")
	}

	if err := s.wfile.Close(); err != nil {
		return errors.Wrap(err, "close write file")
	}

	atomic.StoreInt32(&s.wdone, 1)

	return nil
}

// Close закрытие читалки.
func (s *SimRW) Close() error {
	atomic.StoreInt32(&s.failed, 1)
	if err := s.rfile.Close(); err != nil {
		return err
	}

	return nil
}

// PosRead отдаёт позицию чтения.
func (s *SimRW) PosRead() int64 {
	return s.rfpos
}

// PosWrite отдаёт позицию записи.
func (s *SimRW) PosWrite() int64 {
	return s.wtotal
}

func (s *SimRW) flush() error {
	if len(s.wbuf) == 0 {
		return nil
	}

	if _, err := s.wfile.Write(s.wbuf); err != nil {
		atomic.StoreInt32(&s.failed, 1)
		return err
	}

	atomic.AddInt64(&s.wsize, int64(len(s.wbuf)))
	s.wbuf = s.wbuf[:0]

	return nil
}

func (s *SimRW) setBufferSize(n int) {
	s.wbuf = make([]byte, 0, n)
	s.rbuf = make([]byte, 0, n)
}

func (s *SimRW) setReadPosition(pos int64) {
	s.rfpos = pos
}

func (s *SimRW) setWritePosition(pos int64) {
	s.wsize = pos
	s.wtotal = pos
}

func (s *SimRW) setFsyncOn() {
	s.needFsync = true
}

func (s *SimRW) setErrorLogger(f func(err error)) {
	s.errlog = f
}

var (
	_ ReadOptionsReceiver  = new(SimRW)
	_ WriteOptionsReceiver = new(SimRW)
	_ ErrorLoggerReceiver  = new(SimRW)
)
