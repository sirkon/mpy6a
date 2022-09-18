package fileregistry

// Registry регистратор файлов и операций над ними.
type Registry struct {
	stats Stats

	unused []unusedFile
	logs   []*logFile
	snaps  []*snapshotFile
	merges []*mergeFile
	fixeds []*fixedFile
	tmps   []*tmpFile
}

// New создаёт пустой реестр файлов. Как правило, это требуется только
// при первом запуске системы, ну или при запусках когда не было
// процессов создания слепков.
func New() *Registry {
	return &Registry{}
}

// Clone возвращает копию регистратора данных, которая нужна для создания
// слепка его данных.
//
// WARNING: реализация функция полагается на то, что внутри структур
//  нет ссылочных типов и широко применяет копирование. Если в будущем
//  будут появляться ссылочные типы, то придётся переписывать на ручную
//  конвертацию.
func (r *Registry) Clone() *Registry {
	res := Registry{
		stats:  r.stats,
		unused: r.unused,
		logs:   makeSliceCopy(r.logs),
		snaps:  makeSliceCopy(r.snaps),
		merges: makeSliceCopy(r.merges),
		fixeds: makeSliceCopy(r.fixeds),
		tmps:   makeSliceCopy(r.tmps),
	}
	return &res
}

// Logs возвращает контроллеры файлов логов.
func (r *Registry) Logs() []*FileLog {
	res := make([]*FileLog, len(r.logs))
	for i, log := range r.logs {
		res[i] = &FileLog{
			r:   r,
			log: log,
		}
	}

	return res
}

// Snapshots возвращает контроллеры файлов слепков.
func (r *Registry) Snapshots() []*FileSnapshot {
	res := make([]*FileSnapshot, len(r.snaps))
	for i, snap := range r.snaps {
		res[i] = &FileSnapshot{
			r:    r,
			snap: snap,
		}
	}

	return res
}

// Merges возвращает контроллеры файлов слияний.
func (r *Registry) Merges() []*FileMerge {
	res := make([]*FileMerge, len(r.merges))
	for i, merge := range r.merges {
		res[i] = &FileMerge{
			r:     r,
			merge: merge,
		}
	}

	return res
}

// Fixeds возвращает контроллеры ФЗП файлов.
func (r *Registry) Fixeds() []*FileFixed {
	res := make([]*FileFixed, len(r.fixeds))
	for i, fixed := range r.fixeds {
		res[i] = &FileFixed{
			r:     r,
			fixed: fixed,
		}
	}

	return res
}

// Temporaries возвращает контроллеры временных файлов.
func (r *Registry) Temporaries() []*FileTemporary {
	res := make([]*FileTemporary, len(r.tmps))
	for i, tmp := range r.tmps {
		res[i] = &FileTemporary{
			r: r,
			t: tmp,
		}
	}

	return res
}

// Stats возвращает статистику по файлам.
func (r *Registry) Stats() Stats {
	return r.stats
}

// Данная функция производит клонирование слайса из указателей на значения
// используя промежуточный слайс из самих значений как средство ускорения
// выделения памяти. Она всецело полагается на то, что значения содержат
// в себе только типы-значения, без типов-ссылок.
func makeSliceCopy[T any](v []*T) []*T {
	res := make([]*T, len(v))
	vs := make([]T, len(v))
	for i, t := range v {
		vs[i] = *t
		res[i] = &vs[i]
	}

	return res
}
