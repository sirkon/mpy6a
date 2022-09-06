package state

import "github.com/sirkon/mpy6a/internal/types"

type stateFilesDescriptors struct {
	fixedTimeouts map[types.Index]*fileRangeDescriptor
	snapshots     map[types.Index]*fileRangeDescriptor
	merges        map[types.Index]*fileRangeDescriptor
	logs          []logFileDescription

	snapshotIncoming *fileRangeDescriptor
	mergeIncoming    *fileRangeDescriptor
}

type fileRangeDescriptor struct {
	id     types.Index
	start  uint64
	finish uint64
}

type logFileDescription struct {
	id   types.Index
	last types.Index
}
