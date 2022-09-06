package storage

import (
	"path"

	"github.com/sirkon/mpy6a/internal/types"
)

func (s *Storage) name(id types.Index, suffix string) string {
	return path.Join(s.root, id.String(), ".", suffix)
}

func (s *Storage) nameLog(id types.Index) string {
	return s.name(id, "log")
}

func (s *Storage) nameSnap(id types.Index) string {
	return s.name(id, "snap")
}

func (s *Storage) nameMerge(id types.Index) string {
	return s.name(id, "merge")
}

func (s *Storage) nameFixed(id types.Index) string {
	return s.name(id, "fixed")
}
