package storage

import (
	"github.com/sirkon/mpy6a/internal/fileregistry"
	"github.com/sirkon/mpy6a/internal/logio"
	"github.com/sirkon/mpy6a/internal/mpio"
)

// Storage хранилище данных.
type Storage struct {
	rg *fileregistry.Registry

	mem    *rbTree                   // Сохранённые в памяти сессии.
	fixeds map[int32]*mpio.SimWriter // Фиксированные приёмники.
	log    *logio.Writer             //
}
