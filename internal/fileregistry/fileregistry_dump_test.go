package fileregistry

import (
	"bytes"
	"io"
	"testing"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/testlog"
)

func TestRegistryDump(t *testing.T) {
	// Это бестолковый тест ради покрытия – эмулируем ошибки во время записи.

	r := sampleRegistry()
	var buf bytes.Buffer
	dc, err := r.Dump(&buf)
	if err != nil {
		testlog.Error(t, errors.Wrap(err, "dump file registry"))
		return
	}
	if dc != buf.Len() {
		t.Errorf("expected %d dump length got %d", buf.Len(), dc)
	}

	for i := 0; i < buf.Len()-1; i++ {
		w := limitWriter{
			count: 0,
			limit: i,
		}
		_, err := r.Dump(&w)
		if err == nil {
			t.Errorf("error was expected on %d bytes write limit with out of %d bytes required", i, buf.Len())
			return
		}
	}
}

type limitWriter struct {
	count int
	limit int
}

func (l *limitWriter) Write(p []byte) (n int, err error) {
	if len(p)+l.count > l.limit {
		return 0, io.ErrNoProgress
	}

	l.count += len(p)
	return len(p), nil
}

var _ io.Writer = new(limitWriter)
