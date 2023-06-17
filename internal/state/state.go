package state

import "github.com/sirkon/mpy6a/internal/types"

// State состояние.
type State struct {
	id     types.Index
	prevID types.Index
	repeat uint64

	saved  *rbTree
	active activeSessions

	systime types.TimeAtomic
}
