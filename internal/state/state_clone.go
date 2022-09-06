package state

import "github.com/sirkon/mpy6a/internal/types"

// Получение нового состояния достаточного для создания слепка
// данных текущего.
func (s *State) clone() *State {
	res := &State{
		index: s.index,
		descriptors: &stateFilesDescriptors{
			fixedTimeouts: map[types.Index]*fileRangeDescriptor{},
			snapshots:     map[types.Index]*fileRangeDescriptor{},
			merges:        map[types.Index]*fileRangeDescriptor{},
		},
	}
	s.mgreader.reportState(res)
	for _, l := range s.descriptors.logs {
		res.descriptors.logs = append(res.descriptors.logs, logFileDescription{
			id:   l.id,
			last: l.last,
		})
	}

	res.saved = s.saved.Clone()
	res.active = s.cloneActiveSessions()

	return res
}

func (s *State) cloneActiveSessions() map[types.Index]*types.Session {
	if len(s.active) == 0 {
		return map[types.Index]*types.Session{}
	}

	buf := make([]byte, s.stats.activeLength)
	sessions := make([]types.Session, len(s.active))

	res := make(map[types.Index]*types.Session, len(s.active))
	var i int
	var taken int
	for id, sess := range s.active {
		cs := &sessions[i]
		i++

		length := len(sess.data)
		copy(buf[taken:taken+length], sess.data)
		cs.index = sess.index
		cs.lastIndex = sess.lastIndex
		cs.repeats = sess.repeats
		cs.theme = sess.theme
		cs.data = buf[taken : taken+length]

		taken += length
		res[id] = cs
	}

	return res
}
