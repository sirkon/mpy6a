package storage

import "github.com/sirkon/mpy6a/internal/errors"

// Close закрытие ресурсов хранилища.
func (s *Storage) Close() error {
	if err := s.snapLog.Close(); err != nil {
		return errors.Wrap(err, "close snapshots log")
	}

	return nil
}
