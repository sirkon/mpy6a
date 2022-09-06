package state

import (
	"encoding/binary"

	"github.com/sirkon/mpy6a/internal/types"
)

func (s *State) applySessionRewrite(sessionID types.Index, data []byte) error {
	// _ = data[0]
	// _ = 1 / sessionID.Term

	sess, ok := s.active[sessionID]
	if !ok {
		return errorInternalUnknownSession(sessionID)
	}

	var buf [16]byte
	l := binary.PutUvarint(buf[:16], uint64(len(data)))
	sess.data = append(sess.data, buf[:l]...)
	sess.data = append(sess.data, data...)

	s.stats.activeLength += uint64(l + len(data))

	return nil
}
