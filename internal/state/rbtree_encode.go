package state

import (
	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/sourceio"
	"github.com/sirkon/mpy6a/internal/uvarints"
)

// Encode кодирование данных дерева для создания слепка.
func (t *rbTree) Encode(dst *sourceio.Writer) error {
	if _, err := uvarints.Write(dst, uint64(t.size)); err != nil {
		return errors.Wrap(err, "write sessions count")
	}

	if err := t.write(dst); err != nil {
		return errors.Wrap(err, "write sessions data")
	}

	return nil
}

// Dump сброс данных состояния в источник.
func (t *rbTree) Dump(w *sourceio.Writer) error {
	return t.write(w)
}

func (t *rbTree) write(w *sourceio.Writer) error {
	iter := t.Iter()
	for iter.Next() {
		item := iter.Item()
		for _, sess := range item.Sessions {
			if err := w.SaveSession(item.Repeat, &sess); err != nil {
				return errors.Wrap(err, "save session").SessionID(sess.ID)
			}
		}
	}

	return nil
}
