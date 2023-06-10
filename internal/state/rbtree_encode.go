package state

import (
	"encoding/binary"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/mpio"
	"github.com/sirkon/mpy6a/internal/types"
	"github.com/sirkon/mpy6a/internal/uvarints"
)

// Encode кодирование данных дерева.
func (t *rbTree) Encode(dst mpio.DataWriter) error {
	if _, err := uvarints.Write(dst, uint64(t.size)); err != nil {
		return errors.Wrap(err, "write sessions count")
	}

	iter := t.Iter()
	var buf []byte
	var repbuf [8]byte
	for iter.Next() {
		item := iter.Item()
		for _, sess := range item.Sessions {
			binary.LittleEndian.PutUint64(repbuf[:], item.Repeat)
			if _, err := dst.Write(repbuf[:]); err != nil {
				return errors.Wrap(err, "write session repeat time")
			}
			buf = types.SessionEncode(buf[:0], &sess)
			if _, err := uvarints.Write(dst, uint64(len(buf))); err != nil {
				return errors.Wrap(err, "write encoded session data length").SessionID(sess.ID)
			}
			if _, err := dst.Write(buf); err != nil {
				return errors.Wrap(err, "write encoded session data").SessionID(sess.ID)
			}
		}
	}

	return nil
}
