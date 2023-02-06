package storage

import (
	"path/filepath"

	"github.com/sirkon/mpy6a/internal/types"
)

func (s *Storage) basedName(what string, id types.Index) string {
	return filepath.Join(s.datadir, what+"-"+id.String())
}

func (s *Storage) logName(id types.Index) string {
	return s.basedName("log", id)
}

func (s *Storage) snapName(id types.Index) string {
	return s.basedName("snapshot", id)
}

func (s *Storage) mergeName(id types.Index) string {
	return s.basedName("merge", id)
}

func (s *Storage) fixedName(id types.Index) string {
	return s.basedName("fixed", id)
}

func (s *Storage) tmpName(id types.Index) string {
	return s.basedName("tmp", id)
}
