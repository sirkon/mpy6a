package state

import "github.com/sirkon/mpy6a/internal/types"

// Descriptors хранилище описаний файлов. Хранит как
// описания файлов находящихся в использовании, так и
// более не используемых.
type Descriptors struct {
	srcs     map[types.Index]*srcDescriptor
	log      *logDescriptor
	usedSrcs []usedSrc
	usedLogs []*logDescriptor
}

// srcDescriptor описание источника.
type srcDescriptor struct {
	id     types.Index
	curPos uint64
	len    uint64
}

// logDescriptor описание лога.
type logDescriptor struct {
	id      types.Index
	firstID types.Index
	lastID  types.Index
	len     uint64
}

type usedSrc struct {
	id  types.Index
	len uint64
}
