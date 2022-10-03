package logio

import (
	"fmt"
	"os"
	"strconv"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/uvarints"
)

// WriterOption тип опции для создания писалки логов.
type WriterOption interface {
	String() string
	apply(w *Writer, file *os.File) error
}

// WriterBufferSize задаёт размер буфера в числе .
func WriterBufferSize(size int) WriterOption {
	return writerBufferSize(size)
}

type writerBufferSize int

func (o writerBufferSize) String() string {
	return fmt.Sprintf("set writer buffer size to %d bytes", o)
}

func (o writerBufferSize) apply(w *Writer, _ *os.File) error {
	if int(o) > frameSizeHardLimit {
		return errors.Newf("buffer capacity cannot be larger than %d", frameSizeHardLimit)
	}

	maxRecordLen := 16 + uvarints.LengthInt(w.limit) + w.limit

	if int(o) < maxRecordLen*reasonableBufferCapacityInEvents {
		return errors.Newf(
			"buffer must be large enough to contain at least %d events, this is %d bytes at least, got %d",
			reasonableBufferCapacityInEvents,
			maxRecordLen*reasonableBufferCapacityInEvents,
			o,
		)
	}

	w.bufsize = int(o)
	return nil
}

// WriterPosition задаёт позицию записи в файле.
func WriterPosition(pos uint64) WriterOption {
	return writerPos(pos)
}

type writerPos uint64

func (o writerPos) String() string {
	return "set write position to " + strconv.Itoa(int(o))
}

func (o writerPos) apply(w *Writer, file *os.File) error {
	if uint64(o) < 16 {
		return errors.Newf("write position cannot be lower than 16").
			Uint64("invalid-write-position", uint64(o))
	}

	w.pos = uint64(o)
	if _, err := file.Seek(int64(o), 0); err != nil {
		return errors.Wrap(err, "seek to the write position").Uint64("write-position", uint64(o))
	}

	return nil
}
