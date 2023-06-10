package errors

import "fmt"

// SessionID добавляет в контекст значение с ключом session-id.
func (e Error) SessionID(sess fmt.Stringer) Error {
	return e.Stg("session-id", sess)
}
