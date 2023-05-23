package mpio

import (
	"bytes"
	"io"
	"os"
	"testing"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/tlog"
)

func TestSimWriterOverrideData(t *testing.T) {
	const name = "testdata/simwriter-data-override"
	_ = os.RemoveAll(name)

	w, err := NewSimWriter(name, SimWriterOptions().Logger(errorLogger(t)))
	if err != nil {
		tlog.Error(t, errors.Wrap(err, "create writer on the new file"))
		return
	}

	if _, err := w.Write([]byte("Hello World!")); err != nil {
		tlog.Error(t, errors.Wrap(err, "write data"))
		return
	}

	if err := w.Close(); err != nil {
		tlog.Error(t, errors.Wrap(err, "close writer"))
		return
	}

	w, err = NewSimWriter(name, SimWriterOptions().Logger(errorLogger(t)).WritePosition(10))
	if err != nil {
		tlog.Error(t, errors.Wrap(err, "open writer on existing file with an offset"))
		return
	}

	if _, err := w.Write([]byte("g")); err != nil {
		tlog.Error(t, errors.Wrap(err, "write with override"))
		return
	}

	if err := w.Close(); err != nil {
		tlog.Error(t, errors.Wrap(err, "close second writer"))
	}

	r, err := NewSimReader(w, SimReaderOptions())
	if err != nil {
		tlog.Error(t, errors.Wrap(err, "open reader"))
	}

	var buf bytes.Buffer
	if _, err := io.Copy(&buf, r); err != nil {
		tlog.Error(t, errors.Wrap(err, "copy written data"))
	}

	const expected = "Hello Worlg"
	if buf.String() != expected {
		t.Errorf("expected %q got %q", expected, buf.String())
		return
	}
}

func errorLogger(t *testing.T) func(err error) {
	return func(err error) {
		tlog.Error(t, err)
	}
}
