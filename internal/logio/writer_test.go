package logio

import (
	"os"
	"strconv"
	"testing"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/tlog"
	"github.com/sirkon/mpy6a/internal/types"
)

// Три сценария открытия писалки:
//
//  - Новый файл.
//  - Файл существует, но пуст.
//  - Файл существует.
func TestNewWriter(t *testing.T) {
	t.Run("new file", func(t *testing.T) {
		const name = "testdata/new-file"

		writer, err := NewWriter(name, 160, 20)
		if err != nil {
			tlog.Error(t, errors.Wrap(err, "create new log writer"))
			return
		}

		if writer.pos != fileMetaInfoHeaderSize {
			t.Errorf("expected pos %d, got %d", fileMetaInfoHeaderSize, writer.pos)
		}

		if err := writer.Close(); err != nil {
			tlog.Error(t, errors.Wrap(err, "close writer"))
			return
		}
	})

	t.Run("existing empty file", func(t *testing.T) {
		const name = "testdata/existing-empty-file"

		if err := os.RemoveAll(name); err != nil {
			tlog.Error(t, errors.Wrap(err, "delete log file if exists"))
		}

		create, err := os.Create(name)
		if err != nil {
			tlog.Error(t, errors.Wrap(err, "create log file"))
		}

		if err := create.Close(); err != nil {
			tlog.Error(t, errors.Wrap(err, "close created log file"))
		}

		writer, err := NewWriter(name, 160, 20)
		if err != nil {
			tlog.Error(t, errors.Wrap(err, "create new log writer"))
			return
		}

		if writer.pos != fileMetaInfoHeaderSize {
			t.Errorf("expected pos %d, got %d", fileMetaInfoHeaderSize, writer.pos)
		}

		if err := writer.Close(); err != nil {
			tlog.Error(t, errors.Wrap(err, "close writer"))
			return
		}
	})

	t.Run("reuse existing file", func(t *testing.T) {
		const name = "testdata/existing-file"

		if err := os.RemoveAll(name); err != nil {
			tlog.Error(t, errors.Wrap(err, "delete log file if exists"))
		}

		writer, err := NewWriter(name, 160, 20)
		if err != nil {
			tlog.Error(t, errors.Wrap(err, "create new log writer"))
			return
		}

		if err := writer.Close(); err != nil {
			tlog.Error(t, errors.Wrap(err, "close writer"))
			return
		}

		writer, err = NewWriter(name, 512, 40)
		if err != nil {
			tlog.Error(t, errors.Wrap(err, "create writer with an old file"))
			return
		}

		if writer.pos != fileMetaInfoHeaderSize {
			t.Errorf("expected pos %d, got %d", fileMetaInfoHeaderSize, writer.pos)
		}

		if writer.frame != 160 {
			t.Errorf("expected 160 frame len, got %d", writer.frame)
		}

		if writer.evlim != 20 {
			t.Errorf("expected 20 evlim len, got %d", writer.evlim)
		}

		if err := writer.Close(); err != nil {
			tlog.Error(t, errors.Wrap(err, "close reopened writer"))
			return
		}
	})

	t.Run("reopen-writer", func(t *testing.T) {
		const name = "testdata/active-log-reopen"
		_ = os.RemoveAll(name)

		w, err := NewWriter(name, 512, 40, WriterBufferSize(324))
		if err != nil {
			tlog.Error(t, errors.Wrap(err, "create first writer"))
			return
		}

		for i := 0; i < 40; i++ {
			if _, err := w.WriteEvent(types.NewIndex(1, uint64(i)), []byte(strconv.Itoa(i))); err != nil {
				tlog.Error(t, errors.Wrap(err, "write event").Int("event", i))
				return
			}
		}

		if err := w.Close(); err != nil {
			tlog.Error(t, errors.Wrap(err, "close first writer"))
		}

		w, err = NewWriter(name, 512, 40, WriterBufferSize(324))
		if err != nil {
			tlog.Error(t, errors.Wrap(err, "open the same writer second time"))
			return
		}

		for i := 40; i < 50; i++ {
			if _, err := w.WriteEvent(types.NewIndex(1, uint64(i)), []byte(strconv.Itoa(i))); err != nil {
				tlog.Error(t, errors.Wrap(err, "write event of the second batch").Int("event", i))
				return
			}
		}

		r, err := NewReaderInProcess(w)
		if err != nil {
			tlog.Error(t, errors.Wrap(err, "create reader over the write"))
		}

		var i int
		for r.Next() {
			id, data, _ := r.Event()
			wantID := types.NewIndex(1, uint64(i))
			if !types.IndexEqual(id, wantID) {
				tlog.Error(
					t,
					errors.New("unexpected event id").
						Stg("expected-id", wantID).
						Stg("actual-id", id),
				)
			}
			wantData := strconv.Itoa(i)
			if string(data) != wantData {
				tlog.Error(
					t,
					errors.New("unexpected event data").
						Any("expected-data", []byte(wantData)).
						Any("actual-data", data),
				)
			}
			i++
		}
		if i != 50 {
			tlog.Error(
				t,
				errors.New("not enough events on iteration").
					Int("events-count-expected", 50).
					Int("events-count-actual", i),
			)
		}
		if err := r.Err(); err != nil {
			tlog.Error(t, errors.Wrap(err, "iterate over events"))
		}

		if err := w.Close(); err != nil {
			tlog.Error(t, errors.Wrap(err, "close second writer"))
		}
	})

	t.Run("invalid-params", func(t *testing.T) {
		type test struct {
			name  string
			file  string
			frame int
			limit int
			opts  []WriterOption
		}

		const filename = "testdata/tmp"
		tests := []test{
			{
				name:  "frame is too small",
				file:  filename,
				frame: 5,
				limit: 1,
				opts:  nil,
			},
			{
				name:  "frame is too large",
				file:  filename,
				frame: frameSizeHardLimit + 1,
				limit: 40,
				opts:  nil,
			},
			{
				name:  "evlim is larger than a frame",
				file:  filename,
				frame: 512,
				limit: 513,
				opts:  nil,
			},
			{
				name:  "evlim is too small",
				file:  filename,
				frame: 512,
				limit: 5,
				opts:  nil,
			},
			{
				name:  "can't create a file",
				file:  "/unknown-directory/lol",
				frame: 512,
				limit: 40,
				opts:  nil,
			},
			{
				name:  "buffer size is too small",
				file:  filename,
				frame: 512,
				limit: 40,
				opts:  []WriterOption{WriterBufferSize(5)},
			},
			{
				name:  "buffer is too large",
				file:  filename,
				frame: 512,
				limit: 40,
				opts:  []WriterOption{WriterBufferSize(frameSizeHardLimit + 1)},
			},
		}
		for _, tt := range tests {
			t.Run(tt.name, func(t *testing.T) {
				_ = os.RemoveAll(tt.file)

				w, err := NewWriter(tt.file, tt.frame, tt.limit, tt.opts...)
				if err == nil {
					if err := w.Close(); err != nil {
						tlog.Error(t, errors.Wrap(err, "close unexpectedly opened writer"))
					}

					t.Error("an error was expected here")
					return
				}

				tlog.Log(t, errors.Wrap(err, "expected error"))
			})
		}
	})
}
