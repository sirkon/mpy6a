package mpio

import (
	"bytes"
	"io"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/testlog"
)

// Проверка работы конкурентного чтения и записи.
func TestSimIO(t *testing.T) {
	_ = os.RemoveAll("testdata/simtest")

	w, err := NewSimWriter(
		"testdata/simtest",
		SimWriterOptions().
			BufferSize(4).
			Logger(func(err error) {
				testlog.Error(t, err)
			}),
	)
	if err != nil {
		testlog.Error(t, errors.Wrap(err, "init writer"))
		return
	}

	const N = 3
	var wg sync.WaitGroup
	wg.Add(N)
	var results [N]*bytes.Buffer

	for i := 0; i < N; i++ {
		i := i

		r, err := NewSimReader(w, SimReaderOptions().BufferSize(i+1))
		if err != nil {
			testlog.Error(t, errors.Wrapf(err, "init reader %d", i))
			return
		}
		t.Cleanup(func() {
			if err := r.Close(); err != nil {
				testlog.Error(t, errors.Wrapf(err, "close reader %d", i))
			}
		})

		go func() {
			defer wg.Done()
			var buf bytes.Buffer
			results[i] = &buf

			for {
				var bf [16]byte
				n, err := r.Read(bf[:])
				if err != nil {
					switch err {
					case io.EOF:
						return
					case EOD:
						t.Log(i, "EOD reached")
						time.Sleep(time.Second / 10)
						continue
					default:
						testlog.Error(t, errors.Wrapf(err, "read in the reader %d", i))
						return
					}
				}

				if n == 0 {
					t.Log(i, "empty data read")
					time.Sleep(time.Second / 10)
					continue
				}

				t.Log(i, "got", n, "bytes")

				buf.Write(bf[:n])
			}
		}()
	}

	if _, err := w.Write([]byte("He")); err != nil {
		testlog.Error(t, errors.Wrapf(err, "write first chunk"))
		return
	}

	time.Sleep(time.Second / 5)

	if _, err := w.Write([]byte("llo")); err != nil {
		testlog.Error(t, errors.Wrapf(err, "write second chunk"))
		return
	}

	if _, err := w.Write([]byte(" Wor")); err != nil {
		testlog.Error(t, errors.Wrapf(err, "write third chunk"))
	}

	if _, err := w.Write([]byte("ld!")); err != nil {
		testlog.Error(t, errors.Wrapf(err, "write the last chunk"))
		return
	}

	if err := w.Close(); err != nil {
		testlog.Error(t, errors.Wrap(err, "close writer"))
	}

	wg.Wait()
	for i, result := range results {
		if result.String() != "Hello World!" {
			t.Errorf("Hello World! output expected in reader %d, got %s", i, result.String())
		}

		t.Log(i, result.String())
	}
}
