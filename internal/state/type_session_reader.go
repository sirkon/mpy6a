package state

import "io"

// SessionReader читалка данных сессии должна быть и тем, и тем.
type SessionReader interface {
	io.Reader
	io.ByteReader
}
