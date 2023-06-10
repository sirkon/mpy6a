package state

import (
	"bytes"
	"testing"

	"github.com/sirkon/deepequal"
	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/tlog"
	"github.com/sirkon/mpy6a/internal/types"
)

func TestRBTreePrint(t *testing.T) {
	rb := sampleTree()
	rb.DeleteSessions(200)

	deepequal.SideBySide(t, "trees", rb, rb)
}

func TestRBTreeEncodeDecode(t *testing.T) {
	rb := sampleTree()
	var buf bytes.Buffer
	if err := rb.Encode(&buf); err != nil {
		tlog.Error(t, errors.Wrap(err, "encode session data"))
		return
	}
	var k rbTree
	if err := k.Decode(&buf); err != nil {
		tlog.Error(t, errors.Wrap(err, "decode encoded session data"))
		return
	}

	deepequal.SideBySide(t, "sessions-tree", rb, &k)
}

func sampleTree() *rbTree {
	rb := newRBTree()
	rb.SaveSession(10, types.NewSession(types.NewIndex(1, 1), 12, []byte("Hello")))
	rb.SaveSession(10, types.NewSession(types.NewIndex(1, 2), 13, []byte("World!")))
	rb.SaveSession(300, types.NewSession(types.NewIndex(1, 3), 100, []byte("1234")))
	rb.SaveSession(200, types.NewSession(types.NewIndex(1, 4), 200, []byte("qwerty")))
	return rb
}
