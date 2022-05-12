package state

import (
	"bufio"
	"encoding/binary"
	"io"
)

// SessionTheme тема сессии.
type SessionTheme int32

// Encode сериализация темы
func (t SessionTheme) Encode(dst io.Writer) error {
	var buf [4]byte
	binary.LittleEndian.PutUint32(buf[:4], uint32(t))

	if _, err := dst.Write(buf[:4]); err != nil {
		return err
	}

	return nil
}

// Decode десериализация темы.
func (t *SessionTheme) Decode(src *bufio.Reader) error {
	var buf [4]byte

	if _, err := src.Read(buf[:4]); err != nil {
		return err
	}

	v := binary.LittleEndian.Uint32(buf[:4])
	*t = SessionTheme(v)

	return nil
}
