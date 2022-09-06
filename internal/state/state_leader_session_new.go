package state

import (
	"encoding/binary"

	"github.com/sirkon/mpy6a/internal/types"
)

func (s *State) applySessionNew(theme SessionTheme, data []byte) (types.Index, error) {
	if _, ok := s.active[s.index]; ok {
		return types.Index{}, errorInternalSessionAlreadyExists(s.index)
	}

	buf := make([]byte, s.limits.sessionLength)
	l := binary.PutUvarint(buf, uint64(len(data)))
	buf = append(buf[:l], data...)

	s.active[s.index] = &types.Session{
		index:     s.index,
		lastIndex: s.index,
		repeats:   0,
		data:      buf,
		theme:     theme,
	}

	return s.index, nil
}
