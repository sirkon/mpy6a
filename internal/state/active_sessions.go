package state

import (
	"encoding/binary"
	"io"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/mpio"
	"github.com/sirkon/mpy6a/internal/types"
	"github.com/sirkon/mpy6a/internal/uvarints"
)

type activeSessions map[types.Index]*types.Session

// Encode кодирование активных сессий.
func (a activeSessions) Encode(dst mpio.DataWriter) error {
	if _, err := uvarints.Write(dst, uint64(len(a))); err != nil {
		return errors.Wrap(err, "write sessions count")
	}

	var buf []byte
	for _, sess := range a {
		buf := types.SessionEncode(buf[:0], sess)

		if _, err := uvarints.Write(dst, uint64(len(buf))); err != nil {
			return errors.Wrap(err, "write encoded session length").SessionID(sess.ID)
		}

		if _, err := dst.Write(buf); err != nil {
			return errors.Wrap(err, "write encoded session data").SessionID(sess.ID)
		}
	}

	return nil
}

// Decode декодирование сохранённых данных активных сессий.
func (a activeSessions) Decode(src mpio.DataReader) error {
	length, err := binary.ReadUvarint(src)
	if err != nil {
		return errors.Wrap(err, "read sessions count")
	}

	var buf []byte
	for i := uint64(0); i < length; i++ {
		l, err := binary.ReadUvarint(src)
		if err != nil {
			return errors.Wrap(err, "read session length")
		}

		if l > uint64(cap(buf)) {
			buf = make([]byte, l)
		} else {
			buf = buf[:l]
		}

		if _, err := io.ReadFull(src, buf); err != nil {
			return errors.Wrap(err, "read encoded session data")
		}

		var s types.Session
		if err := types.SessionDecode(&s, buf); err != nil {
			return errors.Wrap(err, "decode encoded session data")
		}

		a[s.ID] = &s
	}

	return nil
}
