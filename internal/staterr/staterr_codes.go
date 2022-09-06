package staterr

import "errors"

// AsCode получить код соответствующий ошибке.
func AsCode(err error) ErrorCode {
	if err == nil {
		return CodeOK
	}

	var target Error
	if !errors.As(err, &target) {
		return CodeInternal
	}

	return target.Code
}

// ErrorCode коды ошибок состояния.
type ErrorCode int32

const (
	// CodeUnknown неиспользуемый код ошибки.
	CodeUnknown = 0

	// CodeOK всё нормально
	CodeOK = 200

	// CodeInternal код внутренней ошибки.
	CodeInternal = 1000

	// CodeSessionLengthOverflow превышение максимальной длины сессии при записи
	CodeSessionLengthOverflow = 2000

	// CodeSessionRepeatLimitReached превышение максимального числа повторов сессии
	CodeSessionRepeatLimitReached = 2001

	// CodeSessionInvalidRequest недопустимые параметры операции пришедшие от пользователя.
	CodeSessionInvalidRequest = 4000
)

func (c ErrorCode) String() string {
	switch c {
	case CodeInternal:
		return "INTERNAL_ERROR"
	case CodeOK:
		return "OK"
	case CodeSessionLengthOverflow:
		return "SESSION_LENGTH_OVERFLOW"
	case CodeSessionRepeatLimitReached:
		return "SESSION_REPEAT_LIMIT_REACHED"
	case CodeSessionInvalidRequest:
		return "SESSION_INVALID_REQUEST"
	default:
		return "UNKNOWN_ERROR"
	}
}
