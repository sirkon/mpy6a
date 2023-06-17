package state

import (
	"bytes"
	"testing"

	"github.com/sirkon/deepequal"
	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/tlog"
	"github.com/sirkon/mpy6a/internal/types"
)

func TestActiveSessionsEncodeDecode(t *testing.T) {
	ss := []types.Session{
		types.NewSession(types.NewIndex(1, 0), 10, []byte("hello")),
		types.NewSession(types.NewIndex(1, 3), 12, []byte("world")),
		types.NewSession(types.NewIndex(2, 1), 10, []byte("привет")),
		types.NewSession(types.NewIndex(2, 2), 10, []byte("мир")),
		types.NewSession(types.NewIndex(2, 3), 10, []byte("你好")),
		types.NewSession(types.NewIndex(2, 3), 10, []byte("世界")),
	}

	as := activeSessions{}
	for _, s := range ss {
		s := s
		as[s.ID] = &s
	}

	var buf bytes.Buffer

	if err := as.Encode(&buf); err != nil {
		tlog.Error(t, errors.Wrap(err, "encode active sessions"))
		return
	}

	bs := activeSessions{}
	if err := bs.Decode(&buf); err != nil {
		tlog.Error(t, errors.Wrap(err, "decode encoded active sessions"))
		return
	}

	deepequal.SideBySide(t, "active sessions", as, bs)
}
