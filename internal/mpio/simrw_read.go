package mpio

import (
	"io"
	"sync/atomic"

	"github.com/sirkon/mpy6a/internal/errors"
)

// Read для реализации io.Reader.
func (s *SimRW) Read(p []byte) (n int, err error) {
	switch s.ensureReadBuffer() {
	case nil:
		n = len(s.rbuf) - s.rbpos
		if n > len(p) {
			n = len(p)
		}
		copy(p, s.rbuf[s.rbpos:s.rbpos+n])
		s.rbpos += n
		s.rfpos += int64(n)
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
func (s *SimRW) ReadByte() (c byte, err error) {
	switch s.ensureReadBuffer() {
	case nil:
		c = s.rbuf[s.rbpos]
		s.rbpos++
		s.rfpos++
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
func (s *SimRW) ensureReadBuffer() error {
	// Если в буфере ещё есть данные, то выходим с успехом
	// сразу же.
	if s.rbpos < len(s.rbuf) {
		return nil
	}

	// В случае если в файле ещё есть данные заполняем
	// буфер из него и выходим.
	s.rbuf = s.rbuf[:0]
	s.rbpos = 0
	wsize := atomic.LoadInt64(&s.wsize)
	if wsize > s.rfpos {
		lim := cap(s.rbuf)
		if lim > int(wsize-s.rfpos) {
			lim = int(wsize - s.rfpos)
		}
		if err := s.fillBuffer(lim); err != nil {
			return errors.Wrap(err, "fill buffer")
		}

		return nil
	}

	// Если данных в файле нет, то нужно проверить содержимое
	// буфера записи, там может что-то быть.
	// Вначале проверяем есть ли что-нибудь, если нет то выходим.
	wdone := atomic.LoadInt32(&s.wdone)
	wtotal := atomic.LoadInt64(&s.wtotal)
	if wtotal == s.rfpos {
		// Если новых данных в файле нет.
		if wdone != 0 {
			// Запись файла окончена, поэтому выходим.
			return io.EOF
		}

		return EOD
	}

	// Получается, что в буфере есть какие-то данные. Нужно заблокировать
	// запись и перенести их.
	s.wlock.Lock()

	// Буфер мог быть сброшен в файл, когда мы дожидались захвата лока.
	// Проверяем это.
	if s.wsize > s.rfpos {
		lim := cap(s.rbuf)
		if lim > int(s.wsize-s.rfpos) {
			lim = int(s.wsize - s.rfpos)
		}

		// Освобождаем дорогу записи как можно быстрее, т.к. за ресурсы чтения
		// мы не конкурируем.
		s.wlock.Unlock()

		if err := s.fillBuffer(lim); err != nil {
			return errors.Wrap(err, "fill buffer with just written data")
		}

		return nil
	}

	// Ну всё, буфер не пуст. Копируем содержимое и выходим.
	d := int(s.wtotal - s.rfpos)
	start := len(s.wbuf) - d
	if d > cap(s.rbuf) {
		d = cap(s.rbuf)
	}
	s.rbuf = s.rbuf[:d]
	copy(s.rbuf, s.wbuf[start:start+d])
	s.rbuf = s.rbuf[:d]
	s.wlock.Unlock()

	return nil
}

func (s *SimRW) fillBuffer(lim int) error {
	if s.needseek {
		s.needseek = false
		if _, err := s.rfile.Seek(s.rfpos, 0); err != nil {
			return errors.Wrap(err, "seek to read position").Int64("desired-position", s.rfpos)
		}
	}

	n, err := s.rfile.Read(s.rbuf[:lim])
	if err != nil {
		if err == io.EOF {
			if n > 0 {
				s.rbuf = s.rbuf[:n]
				s.rbpos = 0
				return nil
			}

			// Это несоответствие между состоянием сущности и файлом:
			// Состояние утверждает что данные в файле есть, но ничего
			// не вычитано.
			err = io.ErrUnexpectedEOF
		}

		return errors.Wrap(err, "read file")
	}

	s.rbuf = s.rbuf[:n]

	return nil
}
