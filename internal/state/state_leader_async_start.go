package state

import (
	"bufio"
	"io"
	"os"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/storage"
	"github.com/sirkon/mpy6a/internal/types"
)

func (s *State) applyAsyncStartSnapshotCreate(cstate *State) error {
	if err := cstate.snapshot(); err != nil {
		return err
	}

	return nil
}

func (s *State) applyAsyncStartLogRotate(id types.Index) error {
	log, err := storage.newOplog(s.logName(id), 0, s.limits.logFrameSize)
	if err != nil {
		return errors.Wrap(err, "create new log file")
	}

	s.asyncArtifacts.newlog = log
	return nil
}

func (s *State) applyAsyncStartMerge(id types.Index, srcs []io.ReadCloser) (err error) {
	file, err := os.Create(s.mergedName(id))
	if err != nil {
		return errors.Wrap(err, "create merge file")
	}
	defer func() {
		if err != nil {
			return
		}

		if err := file.Close(); err != nil {
			err = errors.Wrap(err, "Close merge file")
		}
	}()

	dst := bufio.NewWriter(file)
	defer func() {
		if err != nil {
			return
		}

		if err := dst.Flush(); err != nil {
			err = errors.Wrap(err, "flush merge save buffer")
		}
	}()

	for {
		repeat, _, s2, err2 := r.read()
		if err2 != nil {
			return err2
		}
	}
}

func (s *State) applyAsyncStartFixedTimeoutRotate(id types.Index, to uint32) error {
	dst, err := os.Create(s.fixedTimeoutName(id, int(to)))
	if err != nil {
		return errors.Wrap(err, "create fixed timeout write destination")
	}

	read, err := os.Open(s.fixedTimeoutName(id, int(to)))
	if err != nil {
		return errors.Wrap(err, "open fixed timeout dest for reading")
	}

	cf, err := newConcurrentFile(id, dst, read, 0, 0, s.limits.sessionLength)
	if err != nil {
		return errors.Wrap(err, "setup concurrent fixed timeout file")
	}

	s.asyncArtifacts.ft[to] = cf

	return nil
}
