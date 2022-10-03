package logio

import (
	"os"
	"testing"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/testlog"
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
			testlog.Error(t, errors.Wrap(err, "create new log writer"))
			return
		}

		if writer.pos != fileMetaInfoHeaderSize {
			t.Errorf("expected pos %d, got %d", fileMetaInfoHeaderSize, writer.pos)
		}

		if err := writer.Close(); err != nil {
			testlog.Error(t, errors.Wrap(err, "close writer"))
			return
		}
	})

	t.Run("existing empty file", func(t *testing.T) {
		const name = "testdata/existing-empty-file"

		if err := os.RemoveAll(name); err != nil {
			testlog.Error(t, errors.Wrap(err, "delete log file if exists"))
		}

		create, err := os.Create(name)
		if err != nil {
			testlog.Error(t, errors.Wrap(err, "create log file"))
		}

		if err := create.Close(); err != nil {
			testlog.Error(t, errors.Wrap(err, "close created log file"))
		}

		writer, err := NewWriter(name, 160, 20)
		if err != nil {
			testlog.Error(t, errors.Wrap(err, "create new log writer"))
			return
		}

		if writer.pos != fileMetaInfoHeaderSize {
			t.Errorf("expected pos %d, got %d", fileMetaInfoHeaderSize, writer.pos)
		}

		if err := writer.Close(); err != nil {
			testlog.Error(t, errors.Wrap(err, "close writer"))
			return
		}
	})

	t.Run("reuse existing file", func(t *testing.T) {
		const name = "testdata/existing-file"

		if err := os.RemoveAll(name); err != nil {
			testlog.Error(t, errors.Wrap(err, "delete log file if exists"))
		}

		writer, err := NewWriter(name, 160, 20)
		if err != nil {
			testlog.Error(t, errors.Wrap(err, "create new log writer"))
			return
		}

		if err := writer.Close(); err != nil {
			testlog.Error(t, errors.Wrap(err, "close writer"))
			return
		}

		writer, err = NewWriter(name, 512, 40)
		if err != nil {
			testlog.Error(t, errors.Wrap(err, "create writer with an old file"))
			return
		}

		if writer.pos != fileMetaInfoHeaderSize {
			t.Errorf("expected pos %d, got %d", fileMetaInfoHeaderSize, writer.pos)
		}

		if writer.frame != 160 {
			t.Errorf("expected 160 frame len, got %d", writer.frame)
		}

		if writer.limit != 20 {
			t.Errorf("expected 20 limit len, got %d", writer.limit)
		}

		if err := writer.Close(); err != nil {
			testlog.Error(t, errors.Wrap(err, "close reopened writer"))
			return
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
				name:  "limit is larger than a frame",
				file:  filename,
				frame: 512,
				limit: 513,
				opts:  nil,
			},
			{
				name:  "limit is too small",
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
				name:  "invalid position",
				file:  filename,
				frame: 512,
				limit: 40,
				opts:  []WriterOption{WriterPosition(2)},
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
						testlog.Error(t, errors.Wrap(err, "close unexpectedly opened writer"))
					}

					t.Error("an error was expected here")
					return
				}

				testlog.Log(t, errors.Wrap(err, "expected error"))
			})
		}
	})
}
