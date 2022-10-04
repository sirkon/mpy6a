package logio

import (
	"fmt"
	"strconv"
	"testing"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/mpio"
	"github.com/sirkon/mpy6a/internal/testlog"
	"github.com/sirkon/mpy6a/internal/types"
)

func TestLookup(t *testing.T) {
	const name = "testdata/lookup"
	w, err := NewWriter(name, 128, 32)
	if err != nil {
		testlog.Error(t, errors.Wrap(err, "create log writer"))
		return
	}
	t.Cleanup(func() {
		if err := w.Close(); err != nil {
			testlog.Error(t, errors.Wrap(err, "close log writer"))
		}
	})

	for i := 0; i < 500; i++ {
		if _, err := w.WriteEvent(types.NewIndex(1, uint64(i*2)), []byte(strconv.Itoa(i*i))); err != nil {
			testlog.Error(t, errors.Wrapf(err, "write event %d", i))
		}
	}

	type test struct {
		eventID types.Index
		wantID  types.Index
	}

	tests := []test{
		{
			eventID: types.NewIndex(1, 100),
		},
		{
			eventID: types.NewIndex(1, 101),
			wantID:  types.NewIndex(1, 100),
		},
		{
			eventID: types.NewIndex(1, 102),
			wantID:  types.NewIndex(1, 102),
		},
		{
			eventID: types.NewIndex(1, 499),
			wantID:  types.NewIndex(1, 498),
		},
		{
			eventID: types.NewIndex(1, 997),
			wantID:  types.NewIndex(1, 996),
		},
	}
	for _, tt := range tests {
		t.Run(fmt.Sprintf("look for %s", tt.eventID), func(t *testing.T) {
			if tt.wantID.Term == 0 {
				tt.wantID = tt.eventID
			}

			r, err := mpio.NewSimReader(w.dst, mpio.SimReaderOptions())
			if err != nil {
				testlog.Error(t, errors.Wrapf(err, "open log reader"))
				return
			}

			res, _, _, err := Lookup(r, tt.eventID, w.Pos())
			if err != nil {
				testlog.Error(t, errors.Wrapf(err, "lookup for the event"))
				return
			}

			if !types.IndexEqual(res, tt.wantID) {
				t.Errorf("expected %s got %s", tt.wantID, res)
			}
		})
	}
}
