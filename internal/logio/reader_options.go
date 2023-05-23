package logio

import (
	"fmt"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/types"
)

// ReaderOption тип опции для создания итератора по логу.
type ReaderOption interface {
	String() string
	apply(ri *ReadIterator, file logReader) error
}

// ReaderStart устанавливает начальную позицию чтения.
func ReaderStart(offset uint64) ReaderOption {
	return readerOptionStart(offset)
}

// ReaderReadBefore читает только события до данного.
func ReaderReadBefore(index types.Index) ReaderOption {
	return readerOptionReadBefore(index)
}

// ReaderReadTo читает только события по данное, т.е. включительно.
func ReaderReadTo(index types.Index) ReaderOption {
	return readerOptionReadTo(index)
}

type readerOptionStart uint64

func (r readerOptionStart) String() string {
	return fmt.Sprintf("move read start position to %d", r)
}

func (r readerOptionStart) apply(ri *ReadIterator, file logReader) error {
	if n, err := file.Seek(int64(r), 0); err != nil {
		return errors.Wrap(err, "seek to the position").Uint64("seek-pos", uint64(r))
	} else if n < int64(r) {
		return errors.New("the offset value is too large for the file").
			Uint64("offset", uint64(r)).
			Int64("file-size", n)
	}

	ri.pos = uint64(r)
	return nil
}

type readerOptionReadBefore types.Index

func (r readerOptionReadBefore) String() string {
	return fmt.Sprintf("read events before the %s", types.Index(r))
}

func (r readerOptionReadBefore) apply(ri *ReadIterator, file logReader) error {
	ri.before = types.Index(r)
	return nil
}

type readerOptionReadTo types.Index

func (r readerOptionReadTo) String() string {
	return fmt.Sprintf("read events to the %s", types.Index(r))
}

func (r readerOptionReadTo) apply(ri *ReadIterator, file logReader) error {
	ri.before = types.IndexIncIndex(types.Index(r))
	return nil
}
