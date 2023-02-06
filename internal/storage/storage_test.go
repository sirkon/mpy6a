package storage

import (
	"bytes"
	"testing"

	"github.com/sirkon/deepequal"
	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/fileregistry"
	"github.com/sirkon/mpy6a/internal/testlog"
	"github.com/sirkon/mpy6a/internal/types"
)

func TestStorageDumpRestore(t *testing.T) {
	rg := fileregistry.New()
	rg.NewTemporary(types.NewIndex(1, 1))
	rg.NewFixed(types.NewIndex(1, 2), 30)
	rg.NewSnapshot(types.NewIndex(1, 3), 512, 1024)
	rb := newRBTree()
	rb.SaveSession(10, types.NewSession(types.NewIndex(1, 1), 12, []byte("Hello")))
	rb.SaveSession(10, types.NewSession(types.NewIndex(1, 2), 13, []byte("World!")))
	rb.SaveSession(300, types.NewSession(types.NewIndex(1, 3), 100, []byte("1234")))

	s1 := types.NewSession(types.NewIndex(1, 0), 1, []byte("session-2"))
	s2 := types.NewSession(types.NewIndex(1, 1), 1, []byte("session-1"))
	s := &Storage{
		rg:  rg,
		mem: rb,
		active: map[types.Index]*types.Session{
			types.NewIndex(1, 0): &s1,
			types.NewIndex(1, 1): &s2,
		},
	}

	var buf bytes.Buffer
	_, dumplen, err := s.Dump(&buf)
	if err != nil {
		testlog.Error(t, errors.Wrap(err, "dump storage"))
		return
	}

	if dumplen != uint64(buf.Len()) {
		t.Errorf("expected %d dump length got %d", buf.Len(), dumplen)
		return
	}

	rs, err := Restore(&buf)
	if err != nil {
		testlog.Error(t, errors.Wrap(err, "restore storage from dump"))
		return
	}

	if !deepequal.Equal(s, rs) {
		t.Error("dump/restore mismatch")
		deepequal.SideBySide(t, "storages", s, rs)
		return
	}
	deepequal.SideBySide(t, "storages", s, rs)
}
