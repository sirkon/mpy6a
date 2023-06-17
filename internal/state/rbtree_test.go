package state

import (
	"bytes"
	"testing"

	"github.com/sirkon/deepequal"
	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/sourceio"
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
	w := sourceio.NewWriter(&buf, 36)
	if err := rb.Encode(w); err != nil {
		tlog.Error(t, errors.Wrap(err, "encode session data"))
		return
	}
	if err := w.Flush(); err != nil {
		tlog.Error(t, errors.Wrap(err, "flush data"))
		return
	}
	var k rbTree
	if err := k.Decode(&buf); err != nil {
		tlog.Error(t, errors.Wrap(err, "decode encoded session data"))
		return
	}

	deepequal.SideBySide(t, "sessions-tree", rb, &k)
}

func TestFileSourceIterator(t *testing.T) {
	rb := sampleTree()
	var buf bytes.Buffer
	w := sourceio.NewWriter(&buf, 1024)
	if err := rb.Dump(w); err != nil {
		tlog.Error(t, errors.Wrap(err, "encode session data"))
		return
	}
	if err := w.Flush(); err != nil {
		tlog.Error(t, errors.Wrap(err, "flush collected data"))
		return
	}

	iter := sourceio.NewIteratorSize(&buf, 0)
	for iter.Next() {
		_, r, s := iter.RepeatData()
		t.Log(r, s.String())
	}
	if err := iter.Err(); err != nil {
		tlog.Error(t, errors.Wrap(err, "iterate over source"))
	}
}

func TestMergeIterators(t *testing.T) {
	rb := sampleTree()
	var buf1 bytes.Buffer
	var buf2 bytes.Buffer
	w := sourceio.NewWriter(&buf1, 1024)
	if err := rb.Dump(w); err != nil {
		tlog.Error(t, errors.Wrap(err, "encode session data 1"))
		return
	}
	if err := w.Flush(); err != nil {
		tlog.Error(t, errors.Wrap(err, "flush collected data 1"))
	}

	modifyRBTree(rb.root)
	w = sourceio.NewWriter(&buf2, 1024)
	if err := rb.Dump(w); err != nil {
		tlog.Error(t, errors.Wrap(err, "encode session data 2"))
		return
	}
	if err := w.Flush(); err != nil {
		tlog.Error(t, errors.Wrap(err, "flush collected data 2"))
		return
	}

	var buf bytes.Buffer
	w = sourceio.NewWriter(&buf, 1024)
	if err := sourceio.MergeSources(w, &buf1, &buf2); err != nil {
		tlog.Error(t, errors.Wrap(err, "merge sources"))
	}
	if err := w.Flush(); err != nil {
		tlog.Error(t, errors.Wrap(err, "flush merged data"))
		return
	}

	it := sourceio.NewIteratorSize(&buf, 1024)
	for it.Next() {
		_, rep, data := it.RepeatData()
		t.Log(rep, data.String())
	}
	if err := it.Err(); err != nil {
		tlog.Error(t, errors.Wrap(err, "iterate over merged source"))
	}
}

func modifyRBTree(t *rbTreeNode) {
	if t == nil {
		return
	}

	for i, s := range t.value.Sessions {
		s.Data.Append([]byte("++"))
		t.value.Sessions[i] = s
	}

	modifyRBTree(t.left)
	modifyRBTree(t.right)
}

func sampleTree() *rbTree {
	rb := newRBTree()
	rb.SaveSession(10, types.NewSession(types.NewIndex(1, 1), 12, []byte("Hello")))
	rb.SaveSession(10, types.NewSession(types.NewIndex(1, 2), 13, []byte("World!")))
	rb.SaveSession(300, types.NewSession(types.NewIndex(1, 3), 100, []byte("1234")))
	rb.SaveSession(200, types.NewSession(types.NewIndex(1, 4), 200, []byte("qwerty")))
	return rb
}
