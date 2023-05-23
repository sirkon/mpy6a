package logio_test

import (
	"os"
	"strconv"
	"testing"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/logio"
	"github.com/sirkon/mpy6a/internal/tlog"
	"github.com/sirkon/mpy6a/internal/types"
)

func TestReadIterator(t *testing.T) {
	prepareFile := func(name string) string {
		res := "testdata/" + name
		if err := os.RemoveAll(res); err != nil {
			tlog.Error(t, errors.Wrap(err, "remove existing file"))
		}

		return res
	}

	filename := prepareFile("read-alone")
	w, err := logio.NewWriter(filename, 128, 32)
	if err != nil {
		tlog.Error(t, errors.Wrap(err, "create writer"))
		return
	}
	defer func() {
		if err := w.Close(); err != nil {
			tlog.Error(t, errors.Wrap(err, "close writer"))
		}
	}()

	const N = 100
	var positions []uint64
	for i := uint64(0); i < N; i++ {
		index := types.NewIndex(1, i)
		if _, err := w.WriteEvent(index, []byte(strconv.Itoa(int(i)))); err != nil {
			tlog.Error(t, errors.Wrap(err, "write event "+index.String()))
			return
		}

		positions = append(positions, w.Pos())
	}

	if err := w.Flush(); err != nil {
		tlog.Error(t, errors.Wrap(err, "flush collected data"))
	}

	type test struct {
		name   string
		it     func() (*logio.ReadIterator, error)
		start  types.Index
		finish types.Index
	}

	tests := []test{
		{
			name: "full read",
			it: func() (*logio.ReadIterator, error) {
				return logio.NewReader(filename)
			},
			start:  types.NewIndex(1, 0),
			finish: types.NewIndex(1, 99),
		},
		{
			name: "read from 3rd",
			it: func() (*logio.ReadIterator, error) {
				return logio.NewReader(filename, logio.ReaderStart(positions[1]))
			},
			start:  types.NewIndex(1, 2),
			finish: types.NewIndex(1, 99),
		},
		{
			name: "read before 50th",
			it: func() (*logio.ReadIterator, error) {
				return logio.NewReader(filename, logio.ReaderReadBefore(types.NewIndex(1, 50)))
			},
			start:  types.NewIndex(1, 0),
			finish: types.NewIndex(1, 49),
		},
		{
			name: "read 4th..48th",
			it: func() (*logio.ReadIterator, error) {
				return logio.NewReader(
					filename,
					logio.ReaderStart(positions[3]),
					logio.ReaderReadTo(types.NewIndex(1, 48)),
				)
			},
			start:  types.NewIndex(1, 4),
			finish: types.NewIndex(1, 48),
		},
		{
			name: "read till the end with the existing writer",
			it: func() (*logio.ReadIterator, error) {
				return logio.NewReaderInProcess(w)
			},
			start:  types.NewIndex(1, 0),
			finish: types.NewIndex(1, 99),
		},
		{
			name: "read from 3rd till the end with existing writer",
			it: func() (*logio.ReadIterator, error) {
				if _, err := w.WriteEvent(types.NewIndex(1, 100), []byte("100")); err != nil {
					return nil, errors.Wrap(err, "write last event")
				}

				res, err := logio.NewReaderInProcess(w, logio.ReaderStart(positions[1]))
				if err != nil {
					return nil, errors.Wrap(err, "open reader over the existing file")
				}

				return res, nil
			},
			start:  types.NewIndex(1, 2),
			finish: types.NewIndex(1, 100),
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			it, err := tt.it()
			if err != nil {
				tlog.Error(t, errors.Wrap(err, "create iterator"))
				return
			}

			if err := checkIteratorEvents(t, it, tt.start, tt.finish); err != nil {
				tlog.Error(t, errors.Wrap(err, "check given iterator"))
			}
		})
	}
}

func checkIteratorEvents(t *testing.T, it *logio.ReadIterator, start, finish types.Index) error {
	defer func() {
		if err := it.Close(); err != nil {
			tlog.Error(t, errors.Wrap(err, "close iterator"))
		}
	}()

	cur := start

	for it.Next() {
		index, data, _ := it.Event()
		if !types.IndexEqual(index, cur) {
			return errors.New("unexpected index").
				Stg("index-want", cur).
				Stg("index-got", index)
		}
		if !types.IndexLE(index, finish) {
			return errors.New("index exceeds finish").
				Stg("index-finish", finish).
				Stg("index-got", index)
		}
		wantData := strconv.Itoa(int(index.Index))
		gotData := string(data)
		if wantData != gotData {
			return errors.New("invalid data").
				Str("data-want", wantData).
				Str("data-got", gotData)
		}

		cur = types.IndexIncIndex(cur)
	}

	if err := it.Err(); err != nil {
		return errors.Wrap(err, "iterate over log")
	}

	if !types.IndexLess(finish, cur) {
		return errors.New("failed to reach the finish").
			Stg("index-finish-want", finish).
			Stg("index-finish-got", types.NewIndex(cur.Term, cur.Index-1))
	}

	return nil
}
