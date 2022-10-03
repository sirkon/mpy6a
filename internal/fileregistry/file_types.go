package fileregistry

import (
	"fmt"

	"github.com/sirkon/mpy6a/internal/types"
)

type fileRegistryUnusedFileType int

const (
	fileRegistryUnusedFileTypeLog fileRegistryUnusedFileType = iota
	fileRegistryUnusedFileTypeSnapshot
	fileRegistryUnusedFileTypeMerge
	fileRegistryUnusedFileTypeFixed
	fileRegistryUnusedFileTypeTmp
)

const (
	// FileTypeLog публичный код файлов логов.
	FileTypeLog = fileRegistryUnusedFileTypeLog
	// FileTypeSnapshot публичный код файлов слепков.
	FileTypeSnapshot = fileRegistryUnusedFileTypeSnapshot
	// FileTypeMerge публичной код файлов слияний.
	FileTypeMerge = fileRegistryUnusedFileTypeMerge
	// FileTypeFixed публичный код ФЗП файлов.
	FileTypeFixed = fileRegistryUnusedFileTypeFixed
	// FileTypeTemporary публичный код временных файлов.
	FileTypeTemporary = fileRegistryUnusedFileTypeTmp
)

func (f fileRegistryUnusedFileType) String() string {
	switch f {
	case fileRegistryUnusedFileTypeLog:
		return "log"
	case fileRegistryUnusedFileTypeSnapshot:
		return "snapshot"
	case fileRegistryUnusedFileTypeMerge:
		return "merge"
	case fileRegistryUnusedFileTypeFixed:
		return "fixed"
	case fileRegistryUnusedFileTypeTmp:
		return "temporary"
	default:
		return fmt.Sprintf("unknown file type %d", f)
	}
}

type unusedFile struct {
	typ      fileRegistryUnusedFileType
	id       types.Index
	lastUsed types.Index
	size     uint64
	delay    int32 // Опциональное поле, используется только для ФЗП файлов.
}

type logFile struct {
	id      types.Index
	lastID  types.Index
	firstID types.Index
	read    uint64
	write   uint64
}

type snapshotFile struct {
	id       types.Index
	read     uint64
	readArea uint64
	size     uint64
}

type mergeFile struct {
	id   types.Index
	read uint64
	size uint64
}

type fixedFile struct {
	id    types.Index
	read  uint64
	write uint64
	delay int32
}

type tmpFile struct {
	id types.Index
}
