package logio

import (
	"io"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/types"
)

// LogSource абстракция для вычитки данных из лога для поиска записей
// произошедших в заданный квант времени.
type LogSource interface {
	io.Reader
	io.ByteReader
	io.Seeker
	io.Closer // Для логики не нужно, но нужно для итератора.
}

// Lookup поиск записи обладающей данным идентификатором. Если такая не найдена,
// то возвращается идентификатор и позиция последней перед ней имеющейся записи.
func Lookup(src LogSource, id types.Index, limit uint64) (hid types.Index, pos uint64, size int, err error) {
	frame, eventLimit, err := readMetadata(src)
	if err != nil {
		return types.Index{}, 0, 0, errors.Wrap(err, "read log metadata")
	}

	hid, pos, size, err = lookup(src, id, frame, eventLimit, fileMetaInfoHeaderSize, limit)
	if err != nil {
		return types.Index{}, 0, 0, errors.Wrap(err, "perform file lookup")
	}

	return hid, pos, size, nil
}

func lookup(
	src LogSource,
	id types.Index,
	frame, eventLimit, left, right uint64,
) (
	hid types.Index,
	pos uint64,
	size int,
	err error,
) {
root:
	for {
		frames := (right - left + frame - 1) / frame

		if frames == 0 {
			return hid, pos, size, nil
		}

		c := left + (frames/2)*frame
		if _, err := src.Seek(int64(c), 0); err != nil {
			return types.Index{}, 0, 0, errors.Wrap(err, "seek to the position").
				Uint64("desired-position", c)
		}

		it := ReadIterator{
			src:   src,
			frame: int(frame),
			limit: int(eventLimit),
			pos:   c,
		}

		ppos := c
		for i := 0; it.Next(); i++ {
			eventID, _, ssize := it.Event()
			if eventID.Term == 0 {
				// Конец кадра, останавливаем.
				break
			}

			switch {
			case types.IndexEqual(eventID, id):
				// Запись найдена.
				return id, ppos, ssize, nil
			case types.IndexLess(eventID, id):
				// Запись относится к более раннему событию, делаем его текущим.
				hid = eventID
				pos = ppos
				size = ssize
			default:
				// Эта запись относится к более позднему событию.
				if i > 0 {
					// Если это не первая запись в кадре, то, получается, предыдущей была запись
					// предшествующая искомой, возвращаем её.
					return hid, pos, size, nil
				}

				// Получается, этот центральный кадр содержит более поздние события, делаем его
				// правым краем
				right = c
				continue root
			}

			ppos += uint64(ssize)
			if (it.pos-left) >= frame || (frame-ppos+left) < 18 {
				break
			}
		}

		if err := it.Err(); err != nil {
			return types.Index{}, 0, 0, errors.Wrap(err, "iterate over frame")
		}

		// Все события были меньше, делаем центр левым краем
		left = c
	}
}
