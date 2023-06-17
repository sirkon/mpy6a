package state

import (
	"encoding/binary"
	"io"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/mpio"
	"github.com/sirkon/mpy6a/internal/types"
)

// Decode чтение и извлечение кодированных данных дерева.
func (t *rbTree) Decode(src mpio.DataReader) error {
	count, err := binary.ReadUvarint(src)
	if err != nil {
		return errors.Wrap(err, "read sessions count")
	}

	var repbuf [8]byte
	var buf []byte
	for i := uint64(0); i < count; i++ {
		if _, err := io.ReadFull(src, repbuf[:8]); err != nil {
			return errors.Wrap(err, "read session repeat time data")
		}
		repeat := binary.LittleEndian.Uint64(repbuf[:])

		datalen, err := binary.ReadUvarint(src)
		if err != nil {
			return errors.Wrap(err, "read session encoded data length")
		}

		if uint64(cap(buf)) < datalen {
			buf = make([]byte, datalen)
		} else {
			buf = buf[:datalen]
		}
		if _, err := io.ReadFull(src, buf); err != nil {
			return errors.Wrap(err, "read session encoded data")
		}

		var s types.Session
		if err := types.SessionDecode(&s, buf); err != nil {
			return errors.Wrap(err, "decode session data")
		}

		t.SaveSession(repeat, s)
	}

	return nil
}
