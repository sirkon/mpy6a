package logio

import (
	"bytes"
	"os"
	"strconv"
	"testing"

	"github.com/sirkon/deepequal"
	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/testlog"
	"github.com/sirkon/mpy6a/internal/types"
)

func TestReaderWithRawFile(t *testing.T) {
	t.Run("new-log-write-read", func(t *testing.T) {
		const name = "testdata/new-log"
		_ = os.RemoveAll(name)

		w, err := NewWriter(name, 512, 40, WriterBufferSize(324))
		if err != nil {
			testlog.Error(t, errors.Wrap(err, "create new writer"))
			return
		}

		for i := 0; i < 40; i++ {
			if _, err := w.WriteEvent(types.NewIndex(1, uint64(i)), []byte(strconv.Itoa(i))); err != nil {
				testlog.Error(t, errors.Wrap(err, "write event").Int("event", i))
				return
			}
		}

		if err := w.Close(); err != nil {
			testlog.Error(t, errors.Wrap(err, "close writer"))
			return
		}

		itr, err := NewReader(name)
		if err != nil {
			testlog.Error(t, errors.Wrap(err, "open log reader"))
		}
		defer func() {
			if err := itr.Close(); err != nil {
				testlog.Error(t, errors.Wrap(err, "close read iterator"))
			}
		}()

		var i int
		for itr.Next() {

			id, data, size := itr.Event()
			t.Log(id, string(data), size)

			expectedID := types.NewIndex(1, uint64(i))
			if !deepequal.Equal(id, expectedID) {
				deepequal.SideBySide(t, "indices", expectedID, id)
				return
			}

			if string(data) != strconv.Itoa(i) {
				t.Errorf("%q event data was expected, got %q", strconv.Itoa(i), string(data))
				return
			}

			i++
		}

		if err := itr.Err(); err != nil {
			testlog.Error(t, errors.Wrap(err, "iterate over events"))
			return
		}
	})

	t.Run("read-active", func(t *testing.T) {
		const name = "testdata/active-log"
		_ = os.RemoveAll(name)

		w, err := NewWriter(name, 512, 40, WriterBufferSize(324))
		if err != nil {
			testlog.Error(t, errors.Wrap(err, "create new writer"))
			return
		}

		for i := 0; i < 40; i++ {
			if _, err := w.WriteEvent(types.NewIndex(1, uint64(i)), []byte(strconv.Itoa(i))); err != nil {
				testlog.Error(t, errors.Wrap(err, "write event").Int("event", i))
				return
			}
		}

		itr, err := NewReaderInProcess(w, fileMetaInfoHeaderSize)
		if err != nil {
			testlog.Error(t, errors.Wrap(err, "init active log reader"))
		}
		defer func() {
			if err := itr.Close(); err != nil {
				testlog.Error(t, err)
			}
		}()

		for itr.Next() {
			eventID, eventData, size := itr.Event()
			t.Log(eventID, string(eventData), size)
		}

		if err := itr.Err(); err != nil {
			testlog.Error(t, errors.Wrap(err, "iterate over log entries"))
			return
		}
	})
}

type bufferClose struct {
	bytes.Buffer
}

func (b *bufferClose) Close() error {
	return nil
}

var _ logReader = &bufferClose{}
