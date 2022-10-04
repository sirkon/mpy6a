package logio

import (
	"os"
	"strconv"
	"testing"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/testlog"
)

func TestSnapshots(t *testing.T) {
	const logname = "testdata/snapshots.log"
	_ = os.RemoveAll(logname)

	s := NewSnapshots(
		logname,
		func(err error) {
			testlog.Error(t, err)
		},
	)

	if name, err := s.ReadName(); err != nil {
		testlog.Error(t, errors.Wrapf(err, "read name from file that does not exist"))
		return
	} else {
		if name != "" {
			t.Errorf("expect %q got %q", "", name)
			return
		} else {
			t.Log("expected state on read snapshot name from missing log file")
		}
	}

	for i := 0; i < 10; i++ {
		expected := "snapshot-" + strconv.Itoa(i)

		if err := s.WriteName(expected); err != nil {
			testlog.Error(t, errors.Wrapf(err, "write snapshot %d name", i))
		}

		name, err := s.ReadName()
		if err != nil {
			testlog.Error(t, errors.Wrap(err, "read snapshot log name"))
		}

		if name != expected {
			t.Errorf("expect %q got %q", expected, name)
			return
		}
	}

	if err := s.Rotate(); err != nil {
		testlog.Error(t, errors.Wrapf(err, "rotate snapshot"))
		return
	}

	expected := "snapshot-9"

	name, err := s.ReadName()
	if err != nil {
		testlog.Error(t, errors.Wrapf(err, "read snapshot log name after rotation"))
		return
	}

	if name != expected {
		t.Errorf("expect %q got %q", expected, name)
		return
	}

	s = NewSnapshots(s.name, s.logger)

	name, err = s.ReadName()
	if err != nil {
		testlog.Error(t, errors.Wrapf(err, "read snapshot log name after rotation"))
		return
	}

	if name != expected {
		t.Errorf("expect %q got %q", expected, name)
		return
	}
}
