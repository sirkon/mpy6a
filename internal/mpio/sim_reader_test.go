package mpio

import (
	"bytes"
	"fmt"
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

func TestSimReaderPosition(t *testing.T) {
	const testReaderPosition = "testdata/simreaderposition"
	_ = os.RemoveAll(testReaderPosition)

	w, err := NewSimWriter(
		testReaderPosition,
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
	t.Cleanup(func() {
		if w.done.Load() {
			return
		}

		if err := w.Close(); err != nil {
			testlog.Error(t, errors.Wrapf(err, "close writer"))
		}
	})

	pieces := []string{"1234", "5678"}
	for i, piece := range pieces {
		if _, err := io.WriteString(w, piece); err != nil {
			testlog.Error(t, errors.Wrapf(err, "write piece %d", i))
		}
	}

	type test struct {
		pos     int64
		data    string
		wantErr bool
	}

	tests := []test{
		{
			pos:     3,
			data:    "45678",
			wantErr: false,
		},
		{
			pos:     5,
			data:    "678",
			wantErr: false,
		},
		{
			pos:     12,
			data:    "",
			wantErr: true,
		},
	}
	for _, tt := range tests {
		t.Run(fmt.Sprintf("read from position %d", tt.pos), func(t *testing.T) {
			r, err := NewSimReader(w, SimReaderOptions().ReadPosition(uint64(tt.pos)))
			if err != nil {
				if tt.wantErr {
					testlog.Log(t, errors.Wrapf(err, "expected error"))
				} else {
					testlog.Error(t, errors.Wrapf(err, "create reader"))
				}
				return
			}
			t.Cleanup(func() {
				if err := r.Close(); err != nil {
					testlog.Error(t, errors.Wrapf(err, "close reader"))
				}
			})

			rawdata, err := readRest(r)
			if err != nil {
				testlog.Error(t, errors.Wrapf(err, "read the rest"))
			}

			data := string(rawdata)
			if data != tt.data {
				testlog.Error(
					t,
					errors.Wrap(err, "unexpected result").
						Str("expected", tt.data).
						Str("actual", data),
				)
			}
		})
	}
}

func TestSimReaderSeek(t *testing.T) {
	const testReaderSeek = "testdata/simreaderseek"
	_ = os.RemoveAll(testReaderSeek)

	w, err := NewSimWriter(
		testReaderSeek,
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
	t.Cleanup(func() {
		if w.done.Load() {
			return
		}

		if err := w.Close(); err != nil {
			testlog.Error(t, errors.Wrapf(err, "close writer"))
		}
	})

	pieces := []string{"1234", "5678"}
	for i, piece := range pieces {
		if _, err := io.WriteString(w, piece); err != nil {
			testlog.Error(t, errors.Wrapf(err, "write piece %d", i))
		}
	}

	r, err := NewSimReader(w, SimReaderOptions())
	if err != nil {
		testlog.Error(t, errors.Wrapf(err, "create reader"))
		return
	}
	t.Cleanup(func() {
		if err := r.Close(); err != nil {
			testlog.Error(t, errors.Wrapf(err, "close reader"))
		}
	})

	type test struct {
		pos     int64
		whence  int
		data    string
		wantErr bool
	}
	tests := []test{
		{
			pos:     1,
			whence:  0,
			data:    "2345678",
			wantErr: false,
		},
		{
			pos:     5,
			whence:  0,
			data:    "678",
			wantErr: false,
		},
		{
			pos:     1,
			whence:  2,
			data:    "8",
			wantErr: false,
		},
		{
			pos:     -1,
			whence:  2,
			data:    "",
			wantErr: true,
		},
	}
	for _, tt := range tests {
		t.Run(
			fmt.Sprintf("seek to position %d whence %d", tt.pos, tt.whence),
			func(t *testing.T) {
				if _, err := r.Seek(tt.pos, tt.whence); err != nil {
					if tt.wantErr {
						testlog.Log(t, errors.Wrapf(err, "expected seek error"))
						return
					}

					testlog.Error(t, errors.Wrapf(err, "seek to the position").
						Int64("failed-position", tt.pos).
						Int("whence", tt.whence))
					return
				}

				rawdata, err := readRest(r)
				if err != nil {
					testlog.Error(t, errors.Wrap(err, "read the rest"))
				}

				data := string(rawdata)
				if data != tt.data {
					t.Errorf("expected read is %q, got %q", tt.data, data)
				}
			},
		)
	}
}

func readRest(r *SimReader) ([]byte, error) {
	var data bytes.Buffer
	for {
		var buf [6]byte
		read, err := r.Read(buf[:])
		if err != nil {
			return nil, err
		}

		if read == 0 {
			break
		}

		data.Write(buf[:read])
	}

	return data.Bytes(), nil
}
