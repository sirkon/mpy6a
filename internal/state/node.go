package state

import (
	"context"

	"github.com/sirkon/mpy6a/internal/types"
)

// AppendEntriesRequest данные запроса метода AppendEntries.
type AppendEntriesRequest struct {
	Term    uint64
	Leader  string
	Prev    types.Index
	Entries [][]byte
}

// AppendEntriesResponse данные ответа на AppendEntries
type AppendEntriesResponse struct {
	CurTerm uint64
	Success bool

	AsyncDone *types.Index
}

// Follower абстракция узла-последователя пакеты.
type Follower interface {
	AppendEntries(ctx context.Context, req *AppendEntriesRequest)
}

type Node struct {
}
