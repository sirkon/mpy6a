package logio

import (
	"encoding/binary"
	"io"
	"os"

	"github.com/sirkon/mpy6a/internal/errors"
)

type (
	logFileProviderProtector struct{}
	namedReadCloser          interface {
		io.ReadCloser
		Name() string
	}

	// LogReadSource источник данных лога
	LogReadSource func(logFileProviderProtector) (_ namedReadCloser, framesize uint64, frameleft uint64, err error)
)

// LogFileFull лог читается из файла целиком.
func LogFileFull(name string) LogReadSource {
	return func(logFileProviderProtector) (namedReadCloser, uint64, uint64, error) {
		// открываем файл
		file, err := os.Open(name)
		if err != nil {
			return nil, 0, 0, err
		}

		size, err := readFrameSize(file)
		if err != nil {
			return nil, 0, 0, errors.Wrapf(err, "read frame size of '%s'", name)
		}

		return file, size, size, nil
	}
}

// LogFileFrom лог читается из файла начиная с указанной позиции и до конца файла.
func LogFileFrom(name string, start uint64) LogReadSource {
	return func(logFileProviderProtector) (_ namedReadCloser, size uint64, left uint64, err error) {
		file, err := os.Open(name)
		if err != nil {
			return nil, 0, 0, errors.Wrapf(err, "open file")
		}

		defer func() {
			if err != nil && file != nil {
				_ = file.Close() // может вызвать ошибку, но достаточно и одной
			}
		}()

		size, err = readFrameSize(file)
		if err != nil {
			return nil, 0, 0, errors.Wrapf(err, "read frame size of '%s'", name)
		}

		pos, err := file.Seek(int64(start), 0)
		if err != nil {
			return nil, 0, 0, errors.Wrapf(
				err,
				"seek to start position %d in the opened file '%s'",
				start,
				name,
			)
		}

		if pos < int64(start) {
			return nil, 0, 0, errors.Wrapf(
				err,
				"start position %d is out of range in '%s'",
				start,
				name,
			)
		}

		left = (start - 8) % size
		return file, size, left, nil
	}
}

// LogFileTo лог читается с начала файла до заданной позиции.
func LogFileTo(name string, finish uint64) LogReadSource {
	return func(logFileProviderProtector) (namedReadCloser, uint64, uint64, error) {
		file, err := os.Open(name)
		if err != nil {
			return nil, 0, 0, err
		}

		size, err := readFrameSize(file)
		if err != nil {
			return nil, 0, 0, errors.Wrapf(err, "read frame size of '%s'", name)
		}

		return &fileLimitReader{
			file:   file,
			reader: io.LimitReader(file, int64(finish)),
		}, size, size, nil
	}
}

// LogFileBetween лог читается из части файла заключённой между указанными позиции.
func LogFileBetween(name string, start, finish uint64) LogReadSource {
	return func(protector logFileProviderProtector) (_ namedReadCloser, size uint64, left uint64, err error) {
		if finish < start {
			return nil, 0, 0, errors.Newf(
				"finish (%d) must not be less than the start (%d)",
				finish,
				start,
			)
		}

		file, err := os.Open(name)
		if err != nil {
			return nil, 0, 0, errors.Wrapf(err, "open file")
		}

		defer func() {
			if err != nil && file != nil {
				_ = file.Close() // может вызвать ошибку, но достаточно и одной
			}
		}()

		size, err = readFrameSize(file)
		if err != nil {
			return nil, 0, 0, errors.Wrapf(err, "read frame size of '%s'", name)
		}

		pos, err := file.Seek(int64(start), 0)
		if err != nil {
			return nil, 0, 0, errors.Wrapf(
				err,
				"seek to start position %d in the opened file '%s'",
				start,
				name,
			)
		}

		if pos < int64(start) {
			return nil, 0, 0, errors.Wrapf(
				err,
				"start position %d is out of range in '%s'",
				start,
				name,
			)
		}

		return &fileLimitReader{
			file:   file,
			reader: io.LimitReader(file, int64(finish-start)),
		}, size, (start - 8) % size, nil
	}
}

type fileLimitReader struct {
	file   *os.File
	reader io.Reader
}

func (f *fileLimitReader) Read(p []byte) (n int, err error) {
	return f.reader.Read(p)
}

// Close для реализации namedReadCloser
func (f *fileLimitReader) Close() error {
	return f.file.Close()
}

// Name для реализации namedReadCloser
func (f *fileLimitReader) Name() string {
	return f.file.Name()
}

func readFrameSize(src *os.File) (uint64, error) {
	var buf [8]byte
	read, err := src.Read(buf[:8])
	if err != nil {
		return 0, errors.Wrapf(err, "read frame size")
	}

	if read < 8 {
		return 0, errors.New("missing frame size header")
	}

	framesize := binary.LittleEndian.Uint64(buf[:8])
	switch {
	case framesize == 0:
		return 0, errors.New("invalid frame size header value 0")
	case framesize > frameSizeHardLimit:
		return 0, errors.Newf("frame size header value %d exceeds limit %d", framesize, frameSizeHardLimit)
	}

	return framesize, nil
}
