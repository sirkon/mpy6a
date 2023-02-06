package logio

import (
	"fmt"
	"os"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/uvarints"
)

// WriterOption тип опции для создания писалки логов.
type WriterOption interface {
	String() string
	apply(w *Writer, file *os.File) error
}

// WriterBufferSize задаёт размер буфера в числе.
func WriterBufferSize(size int) WriterOption {
	return writerBufferSize(size)
}

// WriterFileSize задаёт физический размер файла.
func WriterFileSize(size uint64) WriterOption {
	return writerFileSize(size)
}

type writerBufferSize int

func (o writerBufferSize) String() string {
	return fmt.Sprintf("set writer buffer size to %d bytes", o)
}

func (o writerBufferSize) apply(w *Writer, _ *os.File) error {
	if int(o) > frameSizeHardLimit {
		return errors.Newf("buffer capacity cannot be larger than %d", frameSizeHardLimit)
	}

	maxRecordLen := fileMetaInfoHeaderSize + uvarints.LengthInt(w.limit) + w.limit

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

type writerFileSize uint64

func (s writerFileSize) String() string {
	return fmt.Sprintf("force file size to %d", s)
}

func (s writerFileSize) apply(w *Writer, file *os.File) error {
	if err := file.Truncate(int64(s)); err != nil {
		return err
	}

	return nil
}
