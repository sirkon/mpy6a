//go:build integration

package state

import (
	"bytes"
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/sirkon/errors"
)

func TestSnapshotLog(t *testing.T) {
	const newSnapshotName = "new-snapshot"
	t.Run("from-scratch", func(t *testing.T) {
		const snapshotLogName = "testdata/snapshot-log-from-scratch"

		l, err := NewSnapshotLog(snapshotLogName)
		if err != nil {
			t.Error(errors.Wrap(err, "create snapshot log from scratch"))
			return
		}

		defer func() {
			if err := l.Close(); err != nil {
				t.Error(errors.Wrap(err, "close snapshot log"))
			}

			if err := os.Remove(snapshotLogName); err != nil {
				t.Error(errors.Wrap(err, "remove snapshot log file"))
			}
		}()

		if l.Last() != "" {
			t.Errorf("expected missing last snapshot entry, got '%s'", l.Last())
		}

		if err := l.Append(newSnapshotName); err != nil {
			t.Error(errors.Wrap(err, "append new snapshot entry name"))
			return
		}

		if l.Last() != newSnapshotName {
			t.Errorf("expected last snapshot entry to be '%s', got '%s'", newSnapshotName, l.Last())
			return
		}

		if err := l.Append(newSnapshotName + "-2"); err != nil {
			t.Error(errors.Wrap(err, "append another snapshot entry name"))
			return
		}

		if l.Last() != newSnapshotName+"-2" {
			t.Errorf("expected last snapshot entry to be '%s-2', got '%s'", newSnapshotName, l.Last())
			return
		}
	})

	t.Run("restart-behavior", func(t *testing.T) {
		const snapshotLogName = "testdata/snapshot-log"

		var data bytes.Buffer
		var lastSnapshotName string
		for i := 0; i < snapshotLogNameLengthLimit+1; i++ {
			lastSnapshotName = fmt.Sprintf("snapshot-%d", i+1)
			data.WriteString(lastSnapshotName)
			data.WriteByte('\n')
		}

		if err := os.WriteFile(snapshotLogName, data.Bytes(), 0644); err != nil {
			t.Error(errors.Wrap(err, "create predefined snapshot log"))
			return
		}

		l, err := NewSnapshotLog(snapshotLogName)
		if err != nil {
			t.Error(errors.Wrap(err, "init snapshot log instance on existing source"))
			return
		}

		defer func() {
			if err := l.Close(); err != nil {
				t.Error(errors.Wrap(err, "close snapshot entry"))
			}
		}()

		if l.Last() != lastSnapshotName {
			t.Errorf("'%s' snapshot entry was expected as the last, got '%s'", lastSnapshotName, l.Last())
			return
		}

		if err := l.RotateOvergrown(1); err != nil {
			t.Error(errors.Wrap(err, "rotate overgrown snapshot log"))
		}

		if err := l.Append(newSnapshotName); err != nil {
			t.Error(errors.Wrap(err, "append new snapshot name entry"))
		}

		if l.Last() != newSnapshotName {
			t.Errorf(
				"'%s' snapshot entry was expected as the last, got '%s'",
				newSnapshotName,
				l.Last(),
			)
			return
		}

		if err := l.file.Sync(); err != nil {
			t.Error(errors.Wrap(err, "nobuf snapshot entries"))
			return
		}

		if err := matchFileContent(snapshotLogName, lastSnapshotName+"\nnew-snapshot\n"); err != nil {
			t.Error("check snapshot log content")
		}
	})

	t.Run("name is too long", func(t *testing.T) {
		log, err := NewSnapshotLog(strings.Repeat("0", snapshotLogNameLengthLimit*2))
		if err != nil {
			t.Log(errors.Wrap(err, "expected error"))
			return
		}

		t.Errorf("snapshot created with the name that is too long")
		_ = log.Close()
	})

	t.Run("should not use empty name", func(t *testing.T) {
		log, err := NewSnapshotLog("")
		if err != nil {
			t.Log(errors.Wrap(err, "expected error"))
			return
		}

		t.Errorf("snapshot created with empty name")
		_ = log.Close()
	})

}

func matchFileContent(name string, expected string) error {
	data, err := os.ReadFile(name)
	if err != nil {
		return errors.Wrap(err, "read file")
	}

	if string(data) != expected {
		return errors.New("unexpected file data")
	}

	return nil
}
