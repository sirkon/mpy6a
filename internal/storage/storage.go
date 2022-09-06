package storage

import (
	"path"

	"github.com/sirkon/mpy6a/internal/errors"
)

// Storage сущность управления данными обеспечивающая следующую функциональность:
//
//  - Создание логов слепков, логов, слепков состояния, файлов для записи сохранённых
//    сессий с фиксированным временем повтора, слияний источников сохранённых сессий.
//  - Слияние подходящих для этого источников сохранённых сессий.
//  - Сохранение сессии в память.
//  - Сохранение сессии в файл фиксированного времени повтора.
//  - Вычитка сохранённых сессий.
//  - Удаление старых данных через ведение истории работы с файлами.
type Storage struct {
	root string // Путь по которому хранятся файлы.

	snapLog *snapshotLog
	log     *oplog
}

// New конструктор Storage.
func New(
	root string,
	snapLogName string,
) (*Storage, error) {
	slog, err := newSnapshotLog(path.Join(root, snapLogName))
	if err != nil {
		return nil, errors.Wrap(err, "init snapshot log")
	}

	res := &Storage{
		root:    root,
		snapLog: slog,
	}

	return res, nil
}
