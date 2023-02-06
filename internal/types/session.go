package types

import (
	"encoding/binary"
	"io"

	"github.com/sirkon/mpy6a/internal/errors"
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

// SessionWrite запись сессии в приёмник. Возвращается размер
// записанных данных в байтах.
func SessionWrite(dst io.Writer, s Session) (int, error) {
	var buf [16]byte

	IndexEncode(buf[:], s.ID)
	if _, err := dst.Write(buf[:]); err != nil {
		return 0, errors.Wrap(err, "write session id")
	}

	IndexEncode(buf[:], s.ChangeID)
	if _, err := dst.Write(buf[:]); err != nil {
		return 0, errors.Wrap(err, "write session change id")
	}

	repeatsSize, err := uvarints.Write(dst, uint64(s.Repeats))
	if err != nil {
		return 0, errors.Wrap(err, "write repeats count")
	}

	themeSize, err := uvarints.Write(dst, uint64(s.Theme))
	if err != nil {
		return 0, errors.Wrap(err, "write theme code")
	}

	dataSize, err := uvarints.Write(dst, uint64(len(s.Data)))
	if err != nil {
		return 0, errors.Wrap(err, "write data size")
	}

	if _, err := dst.Write(s.Data); err != nil {
		return 0, errors.Wrap(err, "write data")
	}

	return 32 + repeatsSize + themeSize + dataSize + len(s.Data), nil
}

// ByteReader источник должен уметь отдавать данные побайтово.
type ByteReader interface {
	io.Reader
	io.ByteReader
}

// SessionRead вычитка данных сессии из источника.
func SessionRead(src ByteReader) (s Session, err error) {
	var buf [32]byte

	// Вычитка идентификаторов.
	if _, err := io.ReadFull(src, buf[:32]); err != nil {
		return Session{}, errors.Wrap(err, "read session id and change id")
	}

	s.ID = IndexDecode(buf[:16])
	s.ChangeID = IndexDecode(buf[16:])

	repeats, err := binary.ReadUvarint(src)
	if err != nil {
		return s, errors.Wrap(err, "read repeats count")
	}
	s.Repeats = int32(repeats)

	theme, err := binary.ReadUvarint(src)
	if err != nil {
		return s, errors.Wrap(err, "read theme code")
	}
	s.Theme = int32(theme)

	dataLen, err := binary.ReadUvarint(src)
	if err != nil {
		return s, errors.Wrap(err, "read data length")
	}

	s.Data = make([]byte, dataLen)
	if _, err := io.ReadFull(src, s.Data); err != nil {
		return s, errors.Wrap(err, "read data")
	}

	return s, nil
}
