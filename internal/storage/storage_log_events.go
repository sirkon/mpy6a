package storage

import (
	"encoding/binary"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/types"
	"github.com/sirkon/mpy6a/internal/uvarints"
)

type (
	logEventCode     uint16
	repeatSourceCode uint16
)

const (
	logEventNewSession logEventCode = iota + 1
	logEventSessionAppend
	logEventSessionRewrite
	logEventSessionSave
	logEventSessionClose
	logEventSessionRepeat
	logEventLogRotateStart
	logEventSnapshotCreateStart
	logEventMergeStart
	logEventFixedRotateStart
	logEventAsyncCommit
	logEventAsyncAbort

	// RepeatSourceMemoryCode код источника для данных в памяти.
	RepeatSourceMemoryCode repeatSourceCode = iota + 1
	// RepeatSourceSnapshotCode код источника для слепков.
	RepeatSourceSnapshotCode
	// RepeatSourceMergeCode код источника для слияний.
	RepeatSourceMergeCode
	// RepeatSourceFixedCode код источника для ФВП файлов.
	RepeatSourceFixedCode
)

// LogNewSession запись в лог события "создание новой сессии".
func (s *Storage) LogNewSession(id types.Index) error {
	var buf [2]byte

	binary.LittleEndian.PutUint16(buf[:], uint16(logEventNewSession))

	delta, err := s.log.WriteEvent(id, buf[:])
	if err != nil {
		return err
	}

	s.rg.Log().NextWrite(delta, id)
	return nil
}

// LogSessionAppend запись в лог события "добавление новых данных в сессию".
func (s *Storage) LogSessionAppend(id, sid types.Index, data []byte) error {
	return s.sessionDataWrite(id, sid, data, logEventSessionAppend)
}

// LogSessionRewrite запись в лог события "замена содержимого сессии".
func (s *Storage) LogSessionRewrite(id, sid types.Index, data []byte) error {
	return s.sessionDataWrite(id, sid, data, logEventSessionRewrite)
}

// LogSessionSave запись в лог события "запись сессии на повтор".
func (s *Storage) LogSessionSave(id, sid types.Index, repeat uint64) error {
	var buf [26]byte

	binary.LittleEndian.PutUint16(buf[:], uint16(logEventSessionSave))
	types.IndexEncode(buf[2:], sid)
	binary.LittleEndian.PutUint64(buf[18:], repeat)

	delta, err := s.log.WriteEvent(id, buf[:])
	if err != nil {
		return err
	}

	s.rg.Log().NextWrite(delta, id)
	return nil
}

// LogSessionClose запись в лог события "закрытие сессии".
func (s *Storage) LogSessionClose(id, sid types.Index) error {
	var buf [18]byte

	binary.LittleEndian.PutUint16(buf[:], uint16(logEventSessionClose))
	types.IndexEncode(buf[2:], sid)

	delta, err := s.log.WriteEvent(id, buf[:])
	if err != nil {
		return err
	}

	s.rg.Log().NextWrite(delta, id)
	return nil
}

// LogSessionRepeat повтор сессии из источника.
func (s *Storage) LogSessionRepeat(id types.Index, src RepeatSourceProvider) error {
	var buf [48]byte
	binary.LittleEndian.PutUint16(buf[:], uint16(logEventSessionRepeat))
	var l int

	switch v := src.(type) {
	case RepeatSourceMemory:
		binary.LittleEndian.PutUint16(buf[2:], uint16(RepeatSourceMemoryCode))
		ll := binary.PutUvarint(buf[4:], uint64(v))
		l = 4 + ll
	case RepeatSourceSnapshot:
		binary.LittleEndian.PutUint16(buf[2:], uint16(RepeatSourceSnapshotCode))
		types.IndexEncode(buf[4:], v.ID)
		ll := binary.PutUvarint(buf[20:], uint64(v.Len))
		l = 20 + ll
	case RepeatSourceMerge:
		binary.LittleEndian.PutUint16(buf[2:], uint16(RepeatSourceMergeCode))
		types.IndexEncode(buf[4:], v.ID)
		ll := binary.PutUvarint(buf[20:], uint64(v.Len))
		l = 20 + ll
	case RepeatSourceFixed:
		binary.LittleEndian.PutUint16(buf[2:], uint16(RepeatSourceFixedCode))
		types.IndexEncode(buf[4:], v.ID)
		ll := binary.PutUvarint(buf[20:], uint64(v.Len))
		l = 20 + ll
	default:
		return errors.New("unsupported repeat source").Any("invalid-repeat-source", src)
	}

	delta, err := s.log.WriteEvent(id, buf[:l])
	if err != nil {
		return errors.Wrap(err, "write event")
	}

	s.rg.Log().NextWrite(delta, id)
	return nil
}

// LogLogRotateStart запуск ротации лога.
func (s *Storage) LogLogRotateStart(id types.Index) error {
	return s.asyncEventStart(id, logEventLogRotateStart)
}

// LogSnapshotCreateStart запуск создания слепка.
func (s *Storage) LogSnapshotCreateStart(id types.Index) error {
	return s.asyncEventStart(id, logEventSnapshotCreateStart)
}

// LogMergeStart запуск слияния источников повторов.
func (s *Storage) LogMergeStart(id types.Index, srcs []MergeCouple) error {
	buf := make([]byte, 2+len(srcs)*18)

	binary.LittleEndian.PutUint16(buf, uint16(logEventMergeStart))
	data := buf[2:]

	for _, src := range srcs {
		binary.LittleEndian.PutUint16(data, uint16(src.Code))
		types.IndexEncode(data[2:], src.ID)
		data = data[18:]
	}

	delta, err := s.log.WriteEvent(id, buf)
	if err != nil {
		return err
	}

	s.rg.Log().NextWrite(delta, id)
	return nil
}

// LogFixedRotateStart запуск ротации ФВП-файла.
func (s *Storage) LogFixedRotateStart(id types.Index, delay uint32) error {
	var buf [6]byte

	binary.LittleEndian.PutUint16(buf[:], uint16(logEventFixedRotateStart))
	binary.LittleEndian.PutUint32(buf[2:], delay)

	delta, err := s.log.WriteEvent(id, buf[:])
	if err != nil {
		return err
	}

	s.rg.Log().NextWrite(delta, id)
	return nil
}

// LogAsyncEventCommit подтверждение успеха текущей асинхронной операции.
func (s *Storage) LogAsyncEventCommit(id types.Index) error {
	var buf [2]byte
	binary.LittleEndian.PutUint16(buf[:], uint16(logEventAsyncCommit))

	delta, err := s.log.WriteEvent(id, buf[:])
	if err != nil {
		return err
	}

	s.rg.Log().NextWrite(delta, id)
	return nil
}

// LogAsyncEventAbort остановка и удаление состояния текущей асинхронной операции.
func (s *Storage) LogAsyncEventAbort(id types.Index) error {
	var buf [2]byte
	binary.LittleEndian.PutUint16(buf[:], uint16(logEventAsyncAbort))

	delta, err := s.log.WriteEvent(id, buf[:])
	if err != nil {
		return err
	}

	s.rg.Log().NextWrite(delta, id)
	return nil
}

func (s *Storage) sessionDataWrite(id types.Index, sid types.Index, data []byte, method logEventCode) error {
	reqLen := 18 + uvarints.Length(data) + len(data)
	if len(s.eventBuf) < reqLen {
		s.eventBuf = make([]byte, reqLen)
	}
	buf := s.eventBuf[:reqLen]

	binary.LittleEndian.PutUint16(buf[:], uint16(method))
	types.IndexEncode(buf[2:], sid)
	ll := binary.PutUvarint(buf[18:], uint64(len(data)))
	copy(buf[ll+18:], data)

	delta, err := s.log.WriteEvent(id, buf)
	if err != nil {
		return err
	}

	s.rg.Log().NextWrite(delta, id)
	return nil
}

func (s *Storage) asyncEventStart(id types.Index, code logEventCode) error {
	var buf [2]byte

	binary.LittleEndian.PutUint16(buf[:], uint16(code))

	delta, err := s.log.WriteEvent(id, buf[:])
	if err != nil {
		return err
	}

	s.rg.Log().NextWrite(delta, id)
	return nil
}
