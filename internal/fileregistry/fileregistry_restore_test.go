package fileregistry

import (
	"bytes"
	"testing"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/testlog"
)

func TestFileRegistryRestore(t *testing.T) {
	// В этом тесте мы пытаемся распаковать неполные запакованные данные.
	// Каждый такой случай должен оканчиваться ошибкой.

	r := sampleRegistry()
	var buf bytes.Buffer
	if err := r.Dump(&buf); err != nil {
		testlog.Error(t, errors.Wrap(err, "dump registry"))
		return
	}

	for i := 0; i < buf.Len()-1; i++ {
		src := bytes.NewReader(buf.Bytes()[:i])
		_, err := FromSnapshot(src)
		if err == nil {
			t.Error("unexpected successful restore with incomplete dumped data")
			return
		}
	}
}
