package storage

import (
	"bufio"
	"encoding/binary"
	"io"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/fileregistry"
	"github.com/sirkon/mpy6a/internal/types"
)

// Restore восстановить состояния хранилища сохранённые в слепке.
func Restore(src io.Reader) (*Storage, error) {
	b := bufio.NewReader(src)
	res := &Storage{
		mem:    newRBTree(),
		active: map[types.Index]*types.Session{},
	}

	if err := res.restoreMem(b); err != nil {
		return nil, errors.Wrap(err, "restore memory saved sessions")
	}

	if err := res.restoreActive(b); err != nil {
		return nil, errors.Wrap(err, "restore active sessions")
	}

	fg, err := fileregistry.FromSnapshot(b)
	if err != nil {
		return nil, errors.Wrap(err, "restore file registry")
	}
	res.rg = fg

	return res, nil
}

func (s *Storage) restoreMem(src *bufio.Reader) error {
	var tmpbuf [8]byte
	if _, err := io.ReadFull(src, tmpbuf[:]); err != nil {
		return errors.Wrap(err, "read length")
	}

	l := binary.LittleEndian.Uint64(tmpbuf[:])
	area := io.LimitReader(src, int64(l))
	ar := bufio.NewReader(area)

	for {
		repeat, sessions, err := restoreSameRepeatSessions(ar)
		if err != nil {
			if err == io.EOF {
				return nil
			}

			return errors.Wrap(err, "restore session of the same repeat")
		}

		for _, session := range sessions {
			s.mem.SaveSession(repeat, session)
		}
	}
}

func (s *Storage) restoreActive(src *bufio.Reader) error {
	count, err := binary.ReadUvarint(src)
	if err != nil {
		return errors.Wrap(err, "read sessions count")
	}

	for i := 0; i < int(count); i++ {
		session, err := types.SessionRead(src)
		if err != nil {
			return errors.Wrap(err, "read session")
		}

		s.active[session.ID] = &session
	}

	return nil
}

func restoreSameRepeatSessions(src *bufio.Reader) (repeat uint64, sessions []types.Session, err error) {
	var buf [8]byte
	if _, err := io.ReadFull(src, buf[:]); err != nil {
		if err == io.EOF {
			return 0, nil, io.EOF
		}

		return 0, nil, errors.Wrap(err, "read repeat time")
	}
	repeat = binary.LittleEndian.Uint64(buf[:])

	count, err := binary.ReadUvarint(src)
	if err != nil {
		return 0, nil, errors.Wrap(err, "read count of sessions")
	}

	for i := 0; i < int(count); i++ {
		sess, err := types.SessionRead(src)
		if err != nil {
			return 0, nil, errors.Wrap(err, "read session data")
		}

		sessions = append(sessions, sess)
	}

	return repeat, sessions, nil
}
