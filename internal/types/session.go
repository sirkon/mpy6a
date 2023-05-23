package types

import (
	"strconv"
	"strings"

	"github.com/sirkon/intypes"
	"github.com/sirkon/varsize"
)

// Session представление данных сессии.
type Session struct {
	// ID идентификатор сессии, равен индексу состояния в момент её создания.
	// Так же это и "время" её первого изменения.
	ID Index

	// ChangeID идентификатор последнего состояния при котором сессия
	// претерпела изменения.
	ChangeID Index

	// Repeats количество повторов которое успела претерпеть сессия.
	Repeats intypes.VU32

	// Theme тема сессии.
	Theme intypes.VU32

	// Data данные сессии.
	Data SessionData
}

func (s *Session) String() string {
	var buf strings.Builder
	buf.WriteString("session(")
	buf.WriteString(s.ID.String())
	buf.WriteString("){Change:")
	buf.WriteString(s.ChangeID.String())
	buf.WriteString(", Chunks:")
	buf.WriteString(strconv.Itoa(len(s.Data.buf)))
	buf.WriteString("}")

	return buf.String()
}

// NewSessionData создание новой сессии.
func NewSessionData(ID Index, theme uint32, data []byte) Session {
	return Session{
		ID:       ID,
		ChangeID: ID,
		Theme:    theme,
		Data: SessionData{
			buf:    [][]byte{data},
			rawlen: varsize.Len(data) + len(data),
		},
	}
}

// SessionLen возвращает длину закодированной сессии.
func SessionLen(s *Session) int {
	return 16 + 16 + // ID + ChangeID
		varsize.Uint(s.Repeats) +
		varsize.Uint(s.Theme) +
		s.Data.Len()
}
