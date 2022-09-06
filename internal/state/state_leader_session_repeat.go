package state

import "github.com/sirkon/mpy6a/internal/types"

func (s *State) applySessionRepeat(sess *types.Session, src sourceReader) error {
	src.Commit(s)
	s.active[sess.index] = sess

	return nil
}
