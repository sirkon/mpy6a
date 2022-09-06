package state

import (
	"encoding/binary"

	"github.com/sirkon/mpy6a/internal/types"
)

func (s *State) applySessionAppend(sessionID types.Index, data []byte) (prevLength int, newLength int, error error) {
	sess, ok := s.active[sessionID]
	if !ok {
		return 0, 0, errorInternalUnknownSession(sessionID)
	}

	prevLength = len(sess.data)
	sess.lastIndex = s.index

	var buf [16]byte
	l := binary.PutUvarint(buf[:16], uint64(len(data)))
	sess.data = append(sess.data, buf[:l]...)
	sess.data = append(sess.data, data...)

	return prevLength, len(sess.data), nil
}
