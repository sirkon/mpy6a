package storage

import "github.com/sirkon/mpy6a/internal/types"

// MergeCouple идентификатор источника сессий участвующего в слиянии.
type MergeCouple struct {
	Code repeatSourceCode
	ID   types.Index
}

func (s *Storage) mergeSources() []MergeCouple {
	// TODO реализовать выборку источников слияния.
	return nil
}
