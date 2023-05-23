package logio

import (
	"bytes"
	"io"
	"os"
	"path/filepath"

	"github.com/sirkon/mpy6a/internal/errors"
)

// Snapshots объект для чтения имён слепков.
type Snapshots struct {
	name     string
	lastSnap string
	logger   func(err error)
}

// NewSnapshots конструктор Snapshots.
func NewSnapshots(name string, logger func(err error)) *Snapshots {
	return &Snapshots{
		name:   name,
		logger: logger,
	}
}

// maxFileNameSize размер имени файла не может превышать 1Кб.
const maxFileNameSize = 1024

// ReadName чтение имени последнего слепка из лога имён слепков.
func (s *Snapshots) ReadName() (string, error) {
	file, err := os.Open(s.name)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}

		return "", errors.Wrap(err, "open file")
	}
	defer func() {
		if err := file.Close(); err != nil {
			s.logger(errors.Wrapf(err, "close snapshots log file"))
		}
	}()

	stat, err := file.Stat()
	if err != nil {
		return "", errors.Wrapf(err, "get file stats")
	}

	readPos := stat.Size() - 1028
	readSize := 1028
	if stat.Size() < maxFileNameSize {
		readPos = 0
		readSize = int(stat.Size())
	}

	data := make([]byte, readSize)
	if _, err := file.ReadAt(data, readPos); err != nil {
		return "", errors.Wrap(err, "read the tail")
	}

	index := bytes.LastIndexByte(data, '\n')
	if index < 0 {
		return "", errors.New("data integrity error, no NL characters found")
	}

	data = data[:index]
	index = bytes.LastIndexByte(data, '\n')
	if index >= 0 {
		data = data[index+1:]
	}

	s.lastSnap = string(data)
	return string(data), nil
}

// WriteName запись имени последнего слепка.
func (s *Snapshots) WriteName(name string) error {
	if len(name) > maxFileNameSize {
		return errors.New("snapshot name is too large").
			Int("snapshot-name-length", len(name)).
			Int("snapshot-name-length-limit", maxFileNameSize)
	}

	file, err := os.OpenFile(s.name, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return errors.Wrapf(err, "open file")
	}
	defer func() {
		if err := file.Close(); err != nil {
			s.logger(errors.Wrapf(err, "close snapshots log file"))
		}
	}()

	var buf bytes.Buffer
	buf.WriteByte('\n')
	buf.WriteString(name)
	buf.WriteByte('\n')
	if _, err := io.Copy(file, &buf); err != nil {
		return errors.Wrap(err, "write snapshot name")
	}

	if err := file.Sync(); err != nil {
		return errors.Wrapf(err, "sync file data")
	}

	s.lastSnap = name
	return nil
}

// Rotate ротация файла.
func (s *Snapshots) Rotate() error {
	if s.lastSnap == "" {
		return errors.New("rotate must be preceded by read or write calls")
	}

	dir, _ := filepath.Split(s.name)
	tmpName := filepath.Join(dir, "temporary-snapshots-log-file")
	if err := os.WriteFile(tmpName, []byte(s.lastSnap+"\n"), 0644); err != nil {
		return errors.Wrapf(err, "write temporary file")
	}

	var failed bool
	defer func() {
		if !failed {
			return
		}

		if err := os.RemoveAll(tmpName); err != nil {
			s.logger(errors.Wrapf(err, "remove temporary snapshots log file"))
		}
	}()

	if err := os.Rename(tmpName, s.name); err != nil {
		return errors.Wrapf(err, "replace old snapshots log file content with temporary file data")
	}

	return nil
}
