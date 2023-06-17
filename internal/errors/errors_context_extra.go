package errors

import "fmt"

// SessionID добавляет в контекст значение с ключом session-id.
func (e Error) SessionID(sess fmt.Stringer) Error {
	return e.Stg("session-id", sess)
}

// SessionNo добавляет в контекс значение uint64 с ключом session-no.
func (e Error) SessionNo(no uint64) Error {
	return e.Uint64("session-no", no)
}
