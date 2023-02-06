package storage

import (
	"bytes"
	"encoding/binary"
	"io"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/types"
	"github.com/sirkon/mpy6a/internal/uvarints"
)

// Dump создание слепка состояния. Возвращает размер созданного
// слепка.
func (s *Storage) Dump(dst io.Writer) (readArea uint64, size uint64, err error) {
	memsave, err := s.dumpMemorySaved(dst)
	if err != nil {
		return 0, 0, errors.Wrap(err, "dump memory saved sessions")
	}

	actsave, err := s.dumpActive(dst)
	if err != nil {
		return 0, 0, errors.Wrap(err, "dump active sessions")
	}

	frcount, err := s.rg.Dump(dst)
	if err != nil {
		return 0, 0, errors.Wrap(err, "dump file registry state")
	}

	return memsave, memsave + actsave + uint64(frcount), nil
}

// Сброс сессий сохранённых в память.
func (s *Storage) dumpMemorySaved(dst io.Writer) (uint64, error) {
	var buf bytes.Buffer
	buf.Write(make([]byte, 8))

	it := s.mem.Iter()
	for it.Next() {
		item := it.Item()
		if _, err := dumpRepeatSessions(&buf, item.Repeat, item.Sessions); err != nil {
			return 0, errors.Wrap(err, "dump repeats").Uint64("failed-repeats-save", item.Repeat)
		}
	}

	binary.LittleEndian.PutUint64(buf.Bytes()[:8], uint64(buf.Len()-8))
	res := uint64(buf.Len())
	if _, err := buf.WriteTo(dst); err != nil {
		return 0, errors.Wrap(err, "write buffered data into destination")
	}

	return res, nil
}

func (s *Storage) dumpActive(dst io.Writer) (uint64, error) {
	var res uint64

	dac, err := uvarints.Write(dst, uint64(len(s.active)))
	if err != nil {
		return 0, errors.Wrap(err, "dump active sessions count")
	}
	res += uint64(dac)

	for id, session := range s.active {
		sc, err := types.SessionWrite(dst, *session)
		if err != nil {
			return 0, errors.Wrap(err, "dump session").Stg("dump-failed-session-id", id)
		}

		res += uint64(sc)
	}

	return res, nil
}

func dumpRepeatSessions(dst io.Writer, repeat uint64, sessions []types.Session) (int, error) {
	var tmpbuf [8]byte
	binary.LittleEndian.PutUint64(tmpbuf[:], repeat)
	l, err := dst.Write(tmpbuf[:])
	if err != nil {
		return 0, errors.Wrap(err, "dump repeat time")
	}

	sc, err := uvarints.Write(dst, uint64(len(sessions)))
	if err != nil {
		return 0, errors.Wrap(err, "dump sessions count")
	}
	l += sc

	for i, session := range sessions {
		sl, err := types.SessionWrite(dst, session)
		if err != nil {
			return 0, errors.Wrapf(err, "dump session index %d", i)
		}

		l += sl
	}

	return l, nil
}
