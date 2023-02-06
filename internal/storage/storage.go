package storage

import (
	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/fileregistry"
	"github.com/sirkon/mpy6a/internal/logio"
	"github.com/sirkon/mpy6a/internal/mpio"
	"github.com/sirkon/mpy6a/internal/types"
)

// New конструктор хранилища.
func New(datadir string, snaplog *logio.Snapshots) (*Storage, error) {
	s := &Storage{
		datadir: datadir,
		snaplog: snaplog,
	}

	snapname, err := snaplog.ReadName()
	if err != nil {
		return nil, errors.Wrap(err, "read snapshots log")
	}

	if snapname != "" {
		// TODO проводим восстановление состояния.
	}

	return s, nil
}

// Storage хранилище данных.
type Storage struct {
	datadir string
	rg      *fileregistry.Registry

	snaplog *logio.Snapshots               // Контроллер лога слепков.
	log     *logio.Writer                  // Лог
	mem     *rbTree                        // Сохранённые в памяти сессии.
	active  map[types.Index]*types.Session // Данные активных сессий.
	fixeds  map[int32]*mpio.SimWriter      // Приёмники ФЗП-сессий.

	eventBuf []byte
}

// Clone создаёт копию данных хранилища необходимых для создания слепка.
func (s *Storage) Clone() *Storage {
	res := &Storage{
		datadir: s.datadir,
		rg:      s.rg.Clone(),
		active:  make(map[types.Index]*types.Session, len(s.active)),
		mem:     s.mem.Clone(),
	}

	for id, session := range s.active {
		ns := *session
		ns.Data = make([]byte, len(session.Data))
		copy(ns.Data, session.Data)
		res.active[id] = &ns
	}

	return res
}

func (s *Storage) firstLogName() string {
	return s.logName(types.NewIndex(1, 0))
}
