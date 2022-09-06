package storage

import (
	"bytes"
	"io"
	"math"
	"os"
	"path/filepath"

	"github.com/sirkon/mpy6a/internal/errors"
)

// SaveSnapshotName сохраняет имя нового слепка.
func (s *Storage) SaveSnapshotName(name string) error {
	return s.snapLog.Append(name)
}

// snapshotLogNameLengthLimit максимальная длина имени слепка, должна быть в диапазоне [8, 2047]
const (
	snapshotLogNameLengthLimit = 1027
)

func _() {
	// Это выражения для compile-time ограничений по величине snapshotLogNameLengthLimit
	const (
		_ uint64 = snapshotLogNameLengthLimit - 9
		_ uint64 = math.MaxUint64 - 2047 + snapshotLogNameLengthLimit
	)
}

// newSnapshotLog конструктор сущности для ведения лога слепков.
func newSnapshotLog(name string) (*snapshotLog, error) {
	switch {
	case len(name) > snapshotLogNameLengthLimit:
		return nil, errors.Newf(
			"name must not be longer than %d bytes, got %d bytes",
			snapshotLogNameLengthLimit,
			len(name),
		)
	case name == "":
		return nil, errors.New("snapshot log name must not be empty")
	}

	res := &snapshotLog{
		name: name,
	}

	file, err := os.OpenFile(name, os.O_RDWR, 0644)
	if err != nil {
		if os.IsNotExist(err) {
			file, err := os.Create(name)
			if err != nil {
				return nil, errors.Wrap(err, "create missing snapshot log file")
			}

			res.file = file
			return res, nil
		}

		return nil, errors.Wrap(err, "open snapshot log file")
	}

	stat, err := file.Stat()
	if err != nil {
		_ = file.Close() // эта ошибка уже неинтересна

		return nil, errors.Wrap(err, "get snapshot log file stat")
	}

	res.file = file
	res.len = uint64(stat.Size())

	if res.len == 0 {
		return res, nil
	}

	if err := res.readLastRecord(); err != nil {
		return nil, errors.Wrap(err, "Read last log record")
	}

	if _, err := res.file.Seek(0, 2); err != nil {
		return nil, errors.Wrap(err, "move file cursor at its end")
	}

	return res, nil
}

// snapshotLog сущность для ведения лога слепков
type snapshotLog struct {
	name string
	last string

	file *os.File
	len  uint64
}

// Last содержимое последней записи в лог
func (l *snapshotLog) Last() string {
	return l.last
}

// Append добавление новой записи в конец лога
func (l *snapshotLog) Append(snapshot string) error {
	var data bytes.Buffer
	data.WriteString(snapshot)
	data.WriteByte('\n')

	// Длина данных у нас здесь достаточно маленькая и запись поэтому должна носить
	// транзакционный характер: или записалось всё, или ничего. Это как раз то, что
	// нам нужно.
	if _, err := io.Copy(l.file, &data); err != nil {
		return err
	}

	l.last = snapshot
	l.len += uint64(len(snapshot) + 1)

	return nil
}

// Проверка, что лог превзошёл заданный размер.
func (l *snapshotLog) checkIfOvergrown(logSizeLimit int) bool {
	return l.len > uint64(logSizeLimit) && l.last != ""
}

// Выполнение подмены слишком распухшего файла с логом имён слепков
// составляя новый, где первая строка будет содержать имя последнего имени файла
// со слепком данных.
func (l *snapshotLog) rotate() error {
	dir, _ := filepath.Split(l.name)
	temp, err := os.CreateTemp(dir, "snapshot-log-rotation")
	if err != nil {
		return errors.Wrap(err, "create temporary file")
	}

	if _, err := temp.WriteString(l.last + "\n"); err != nil {
		return errors.Wrap(err, "write last log entry into the temporary file")
	}

	if err := temp.Sync(); err != nil {
		return errors.Wrap(err, "nobuf written data into the temporary file")
	}

	old := l.file
	if err := os.Rename(temp.Name(), l.name); err != nil {
		return errors.Wrap(err, "replace snapshot log file with the temporary").
			Str("old-log-file-name", l.name).
			Str("temp-file-name", temp.Name())
	}

	l.file = temp
	l.len = uint64(len(l.last) + 1)

	if err := old.Close(); err != nil {
		return errors.Wrap(err, "Close old snapshot log file handler")
	}

	return nil
}

// Close закрывает файл лога имён слепков.
func (l *snapshotLog) Close() error {
	return l.file.Close()
}

func (l *snapshotLog) readLastRecord() error {
	if l.len > snapshotLogNameLengthLimit+1 {
		if _, err := l.file.Seek(int64(l.len-snapshotLogNameLengthLimit-1), 0); err != nil {
			return errors.Wrapf(err, "offset from the end by %d bytes", snapshotLogNameLengthLimit+1)
		}
	}

	data, err := io.ReadAll(l.file)
	if err != nil {
		return errors.Wrap(err, "Read file from the offset")
	}

	split := bytes.Split(data, []byte{'\n'})
	for i := len(split) - 1; i >= 0; i-- {
		rawline := split[i]
		if len(rawline) == 0 {
			continue
		}

		l.last = string(rawline)
		break
	}

	return nil
}
