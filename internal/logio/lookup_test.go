package logio

import (
	"os"
	"testing"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/tlog"
	"github.com/sirkon/mpy6a/internal/types"
)

func TestLookup(t *testing.T) {
	const eventfile = "testdata/lookup_test"
	var (
		eventData = []byte("Hello")
		terms     = []int{1, 2, 4}
	)

	if err := os.RemoveAll(eventfile); err != nil {
		tlog.Error(t, errors.Wrap(err, "delete existing event file"))
	}

	w, err := NewWriter(eventfile, 128, 32, WriterBufferSize(256))
	if err != nil {
		tlog.Error(t, errors.Wrap(err, "create writer"))
		return
	}

	for _, term := range terms {
		for i := 0; i < 100; i++ {
			index := types.NewIndex(uint64(term), uint64(i))
			if _, err := w.WriteEvent(index, eventData); err != nil {
				tlog.Error(t, errors.Wrap(err, "write event").Stg("write-error-index", index))
				return
			}
		}
	}

	if err := w.Close(); err != nil {
		tlog.Error(t, errors.Wrap(err, "close writer"))
		return
	}

	checkNextEvent := func(t *testing.T, pos uint64, next *types.Index) error {
		reader, err := NewReader(eventfile, ReaderStart(pos))
		if err != nil {
			return errors.Wrap(err, "open event file for reading")
		}
		defer func() {
			if err := reader.Close(); err != nil {
				tlog.Error(t, errors.Wrap(err, "close event reader"))
			}
		}()

		if reader.Next() {
			id, _, _ := reader.Event()

			if next == nil {
				return errors.New("unexpected event detected").Stg("unexpected-event-id", id)
			}

			if !types.IndexEqual(id, *next) {
				return errors.New("actual and expected event id mismatch").
					Stg("expected-event-id", *next).
					Stg("actual-event-id", id)
			}
		} else if next != nil {
			return errors.New("missing expected event").Stg("expected-event-id", *next)
		}

		return nil
	}

	type test struct {
		name    string
		id      types.Index
		prev    *types.Index
		next    *types.Index
		wantErr bool
	}

	tests := []test{
		{
			name:    "look for second",
			id:      types.NewIndex(1, 0),
			prev:    nil,
			next:    ptrIndex(1, 1),
			wantErr: false,
		},
		{
			name:    "look for third",
			id:      types.NewIndex(1, 1),
			prev:    nil,
			next:    ptrIndex(1, 2),
			wantErr: false,
		},
		{
			name:    "look for a deep one",
			id:      types.NewIndex(2, 79),
			prev:    nil,
			next:    ptrIndex(2, 80),
			wantErr: false,
		},
		{
			name:    "take closer to the end",
			id:      types.NewIndex(4, 98),
			prev:    nil,
			next:    ptrIndex(4, 99),
			wantErr: false,
		},
		{
			name:    "the last",
			id:      types.NewIndex(4, 99),
			prev:    nil,
			next:    nil,
			wantErr: false,
		},
		{
			name:    "out of bounds",
			id:      types.NewIndex(100, 0),
			prev:    ptrIndex(4, 99),
			next:    nil,
			wantErr: false,
		},
		{
			name:    "missing event",
			id:      types.NewIndex(2, 105),
			prev:    ptrIndex(2, 99),
			next:    ptrIndex(4, 0),
			wantErr: false,
		},
	}
	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			res, err := LookupNext(
				eventfile,
				tt.id,
				func(err error) {
					tlog.Error(t, err)
				},
			)
			if err != nil {
				if tt.wantErr {
					tlog.Log(t, errors.Wrap(err, "expected error"))
				} else {
					tlog.Error(t, errors.Wrap(err, "unexpected error"))
				}
				return
			}

			if tt.wantErr {
				tlog.Error(t, errors.New("lookup error was expected"))
				return
			}

			switch v := res.(type) {
			case LookupResultFound:
				switch {
				case v.Int64() < 0 && tt.next == nil:
					t.Log("expected no next event state")
				case v.Int64() < 0 && tt.next != nil:
					tlog.Error(t, errors.New("no event found").Stg("expected-event-id", *tt.next))
				default:
					if err := checkNextEvent(t, uint64(v.Int64()), tt.next); err != nil {
						tlog.Error(t, err)
					}
				}
				return

			case *LookupResultIsMissing:
				if err := checkNextEvent(t, v.LastBeforeOffset, &v.LastBeforeID); err != nil {
					tlog.Error(t, errors.Wrap(err, "check previous event position"))
					return
				} else {
					t.Log("previous event position checked out")
				}
				if v.NextID.Term != 0 {
					if err := checkNextEvent(t, v.NextOffset, &v.NextID); err != nil {
						tlog.Error(t, errors.Wrap(err, "check next event position"))
						return
					}
					t.Log("next event position checked out")
				}

				if !types.IndexEqual(v.LastBeforeID, *tt.prev) {
					tlog.Error(
						t,
						errors.New("unexpected previous event id").
							Stg("expected-previous-event-id", *tt.prev).
							Stg("actual-previous-event-id", v.LastBeforeID),
					)
				}
				switch {
				case v.NextID.Term != 0 && tt.next != nil:
					if !types.IndexEqual(v.NextID, *tt.next) {
						tlog.Error(
							t,
							errors.New("unexpected next event id").
								Stg("expected-next-event-id", *tt.next).
								Stg("actual-next-event-id", v.NextID),
						)
					}
				case v.NextID.Term != 0 && tt.next == nil:
					tlog.Error(
						t,
						errors.New("unexpected next event").Stg("unexpected-next-event-id", v.NextID),
					)
				case v.NextID.Term == 0 && tt.next != nil:
					tlog.Error(
						t,
						errors.New("missing next event").Stg("expected-next-event-id", *tt.next),
					)
				case v.NextID.Term == 0 && tt.next == nil:
				}
			}
		})
	}
}

func ptrIndex(term, id uint64) *types.Index {
	res := types.NewIndex(term, id)
	return &res
}
