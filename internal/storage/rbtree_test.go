package storage

import (
	"testing"

	"github.com/sirkon/deepequal"
	"github.com/sirkon/mpy6a/internal/types"
)

func TestRBTreePrint(t *testing.T) {
	rb := newRBTree()
	rb.SaveSession(10, types.NewSession(types.NewIndex(1, 1), 12, []byte("Hello")))
	rb.SaveSession(10, types.NewSession(types.NewIndex(1, 2), 13, []byte("World!")))
	rb.SaveSession(300, types.NewSession(types.NewIndex(1, 3), 100, []byte("1234")))

	deepequal.SideBySide(t, "trees", rb, rb)
}
