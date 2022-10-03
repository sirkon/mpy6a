package logio

import (
	"bytes"
	"strconv"
	"testing"

	"github.com/sirkon/deepequal"
	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/testlog"
	"github.com/sirkon/mpy6a/internal/types"
)

func TestReaderWithRawFile(t *testing.T) {
	t.Run("new-log-write-read", func(t *testing.T) {
		w, err := NewWriter("testdata/new-log", 512, 40, WriterBufferSize(324))
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

		itr, err := NewReader("testdata/new-log", w.Pos())
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

			id, data, _ := itr.Event()
			t.Log(id, string(data))

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

	t.Run("reuse-log-file", func(t *testing.T) {
		const name = "testdata/old-log"

		w, err := NewWriter(name, 512, 40, WriterBufferSize(324))
		if err != nil {
			testlog.Error(t, errors.Wrap(err, "create new writer"))
			return
		}

		var prevPos uint64
		var pos uint64
		for i := 0; i < 40; i++ {
			delta, err := w.WriteEvent(types.NewIndex(1, uint64(i)), []byte(strconv.Itoa(i)))
			if err != nil {
				testlog.Error(t, errors.Wrap(err, "write event").Int("event", i))
				return
			}

			prevPos = pos
			pos += uint64(delta)
		}

		if err := w.Close(); err != nil {
			testlog.Error(t, errors.Wrap(err, "close writer"))
		}

		w, err = NewWriter(
			name,
			512,
			40,
			WriterBufferSize(324),
			WriterPosition(prevPos),
		)
		if err != nil {
			testlog.Error(t, errors.Wrap(err, "open reader using existing file"))
		}

		if _, err := w.WriteEvent(types.NewIndex(2, 1), []byte("Hello")); err != nil {
			testlog.Error(t, errors.Wrap(err, "write new event into the log"))
		}

		if err := w.Close(); err != nil {
			testlog.Error(t, errors.Wrap(err, "close reuse writer"))
		}

		itr, err := NewReader(name, w.Pos())
		if err != nil {
			testlog.Error(t, errors.Wrap(err, "open file reader"))
		}
		defer func() {
			if err := itr.Close(); err != nil {
				testlog.Error(t, errors.Wrap(err, "close read iterator"))
			}
		}()

		var eventID types.Index
		var eventData []byte
		for itr.Next() {
			eventID, eventData, _ = itr.Event()
			t.Log(eventID, string(eventData))
		}

		if err := itr.Err(); err != nil {
			testlog.Error(t, errors.Wrap(err, "iterate over log entries"))
			return
		}

		t.Log(eventID, string(eventData))
	})
}

type bufferClose struct {
	bytes.Buffer
}

func (b *bufferClose) Close() error {
	return nil
}

var _ logReader = &bufferClose{}
