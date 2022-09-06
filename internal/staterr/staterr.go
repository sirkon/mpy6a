package staterr

import "strings"

// Error тип ошибки состояния
type Error struct {
	Code ErrorCode
	Msg  string
}

func (e Error) Error() string {
	if e.Msg != "" {
		var b strings.Builder
		b.WriteString(e.Code.String())
		b.WriteByte('[')
		b.WriteString(e.Msg)
		b.WriteByte(']')
		return b.String()
	}

	return e.Code.String()
}

// NewOK нормальное состояние.
func NewOK() Error {
	return Error{
		Code: CodeOK,
	}
}

func newEncodedError(code ErrorCode, msg ...string) Error {
	e := Error{
		Code: code,
	}
	switch len(msg) {
	case 0:
	case 1:
		e.Msg = msg[0]
	default:
		e.Msg = strings.Join(msg, ": ")
	}

	return e
}

// NewSessionLengthOverflow ошибка слишком большой длины сессии.
func NewSessionLengthOverflow(msg ...string) Error {
	return newEncodedError(CodeSessionLengthOverflow, msg...)
}

// NewSessionRepeatLimitReached ошибка слишком большого числа повторов сессии.
func NewSessionRepeatLimitReached(msg ...string) Error {
	return newEncodedError(CodeSessionRepeatLimitReached, msg...)
}

// NewSessionInvalidRequest неправильный запрос.
func NewSessionInvalidRequest(msg ...string) Error {
	return newEncodedError(CodeSessionInvalidRequest, msg...)
}
