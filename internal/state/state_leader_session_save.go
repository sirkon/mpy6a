package state

import (
	"os"

	"github.com/sirkon/mpy6a/internal/errors"
)

func (s *State) applySessionSaveFixedTimeout(repeat uint64, data []byte, to uint32) (err error) {
	fixeds, ok := s.fixeds[to]
	if !ok {
		wfile, err := os.Create(s.fixedTimeoutName(s.index, int(to)))
		if err != nil {
			return errors.Wrap(err, "create file for fixed timeout").
				Stg("state-id", s.index).
				Uint32("fixed-timeout", to)
		}
		rfile, err := os.Open(s.fixedTimeoutName(s.index, int(to)))
		if err != nil {
			return errors.Wrap(err, "open fixed timeout Read").
				Stg("state-id", s.index).
				Uint32("fixed-timeout", to)
		}

		cr, err := newConcurrentFile(s.index, wfile, rfile, 0, 0, uint64(len(s.sessionBuf)))
		if err != nil {
			return errors.Wrap(err, "setup concurrent file for fixed timeout")
		}
		s.fixeds[to] = cr

		concurrent, _ := s.sourceReaderFixedTimeoutFromConcurrent(to)
		s.mgreader.append(concurrent)
	}

	if err := fixeds.WriteSession(repeat, data); err != nil {
		return errors.Wrap(err, "write Session")
	}

	return nil
}

func (s *State) applySessionSaveMemory(repeat uint64, data []byte) error {
	s.saved.Add(repeat, data)
	return nil
}
