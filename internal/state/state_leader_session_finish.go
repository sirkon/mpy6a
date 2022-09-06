package state

import "github.com/sirkon/mpy6a/internal/types"

func (s *State) applySessionFinish(sessionID types.Index) (length int, err error) {
	sess, ok := s.active[sessionID]
	if !ok {
		return 0, errorInternalUnknownSession(sessionID)
	}

	delete(s.active, sessionID)
	return len(sess.data), nil
}
