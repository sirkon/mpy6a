package types

import (
	"encoding/binary"
	"io"

	"github.com/sirkon/mpy6a/internal/byteop"
	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/mpio"
	"github.com/sirkon/mpy6a/internal/uvarints"
)

// Session представление сессии.
type Session struct {
	// ID идентификатор сессии, равен индексу состояния в момент её создания.
	// Так же это и "время" её первого изменения.
	ID Index
	// ChangeID идентификатор последнего состояния при котором сессии
	// претерпела изменения.
	ChangeID Index
	// Repeats количество повторов которые успела претерпеть сессия.
	Repeats int32
	// Theme тема сессии.
	Theme int32
	// Data бинарные данные сессии.
	Data []byte
}

// NewSession создание новой сессии.
func NewSession(ID Index, theme int32, data []byte) Session {
	return Session{
		ID:       ID,
		ChangeID: ID,
		Theme:    theme,
		Data:     data,
	}
}

// SessionReader абстракция источника вычитки данных сессий.
type SessionReader interface {
	io.Reader
	io.ByteReader
}

// SessionEncodeRepeat сериализация сессии для повтора в заданное время в
// представленный приёмник.
// Сериализованные данные представляются следующей последовательностью:
//
//  - Время повтора, 8 байт.
//  - Длина всех данных сессии.
//  - Идентификатор сессии, 16 байт.
//  - Идентификатор последнего изменения сессии, 16 байт,
//  - Число повторов которое успела претерпеть сессия, 4 байта.
//  - "Тема" сессии, 4 байта.
//  - Данные сессии.
func SessionEncodeRepeat(dst *byteop.Buffer, s Session, repeat uint64) {
	l := s.storageLen()

	// Выделяем место в буфере и берём кусок памяти из этого буфера.
	delta := 8 + uvarints.LengthInt(uint64(l)) + l
	buf := dst.Extend(delta)

	// Сейчас кодируем каждый кусок данных.
	binary.LittleEndian.PutUint64(buf, repeat)
	ll := binary.PutUvarint(buf[8:], uint64(l))
	buf = buf[8+ll:]
	IndexEncode(buf, s.ID)
	IndexEncode(buf[16:], s.ChangeID)
	binary.LittleEndian.PutUint32(buf[32:], uint32(s.Repeats))
	binary.LittleEndian.PutUint32(buf[36:], uint32(s.Theme))
	copy(buf[40:], s.Data)
}

// SessionDecodeRepeat декодирование времени повтора и данных сессии из источника.
// Если данных в источнике нет, но они могут появиться позднее возвращается miscio.EOF.
// io.EOF возвращается если источник вычитан до конца и более не пишется.
func SessionDecodeRepeat(src SessionReader) (repeat uint64, session Session, err error) {
	var buf [16]byte
	n, err := mpio.TryReadFull(src, buf[:8])
	if err != nil {
		if err == io.EOF {
			return 0, session, io.EOF
		}

		return 0, session, errors.Wrap(err, "read session repeat time")
	}
	if n == 0 {
		return 0, session, mpio.EOD
	}

	repeat = binary.LittleEndian.Uint64(buf[:8])

	l, err := binary.ReadUvarint(src)
	if err != nil {
		switch err {
		case io.EOF:
			err = io.ErrUnexpectedEOF
		case mpio.EOD:
			err = mpio.ErrUnexpectedEOD
		}

		return 0, session, errors.Wrap(err, "read session data length")
	}

	var meta [40]byte
	if n, err := io.ReadFull(src, meta[:]); err != nil {
		if n != 40 {
			return 0, session, errors.Wrap(err, "read session metadata")
		}
	}

	data := make([]byte, l-40)
	if n, err := io.ReadFull(src, data); err != nil {
		if n != int(l)-40 {
			return 0, session, errors.Wrap(err, "read session encoded data")
		}
	}

	session.ID = IndexDecode(meta[:])
	session.ChangeID = IndexDecode(meta[16:])
	session.Repeats = int32(binary.LittleEndian.Uint32(meta[32:]))
	session.Theme = int32(binary.LittleEndian.Uint32(meta[36:]))
	session.Data = data

	return repeat, session, nil
}

// Размер данных сессии при хранении в источнике.
func (s Session) storageLen() int {
	pureSessionLen := 16 + 16 + 4 + 4 + len(s.Data)
	return pureSessionLen
}
