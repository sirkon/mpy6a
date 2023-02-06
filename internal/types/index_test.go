package types

import (
	"testing"

	"github.com/sirkon/deepequal"
)

func TestIndexAtomic(t *testing.T) {
	id := NewIndexAtomic()

	index := NewIndex(1, 5)
	index2 := NewIndex(2, 6)
	id.Set(index)
	v := id.Get()
	id.Set(index2)
	deepequal.SideBySide(t, "atomic index", index, v)
	w := id.Get()
	deepequal.SideBySide(t, "atomic index change", index2, w)
}
