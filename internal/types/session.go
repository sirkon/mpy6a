package types

import (
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
	buf.WriteString(`, Chunks: [`)
	for i, d := range s.Data.buf {
		if i > 0 {
			buf.WriteString(", ")
		}
		buf.WriteString(string(d))
	}
	buf.WriteByte(']')
	buf.WriteString("}")

	return buf.String()
}

// NewSession создание новой сессии.
func NewSession(ID Index, theme uint32, data []byte) Session {
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

func (s *Session) headersLen() int {
	return 16 + 16 + varsize.Uint(s.Repeats) + varsize.Uint(s.Theme)
}

// SessionRawLen возвращает длину закодированной сессии.
func SessionRawLen(s *Session) int {
	return s.headersLen() + s.Data.Len()
}

// SessionAppendRawLen возвращает размер сессии, которая та примет
// при добавлении нового куска данных.
func SessionAppendRawLen(s *Session, data []byte) int {
	return SessionRawLen(s) + varsize.Len(data) + len(data)
}

// SessionRewriteRawLen возвращает размер сессии, которая та примет
// если её содержимое будет замещено новыми данными.
func SessionRewriteRawLen(s *Session, data []byte) int {
	return s.headersLen() + varsize.Len(data) + len(data)
}
