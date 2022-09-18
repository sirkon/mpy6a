package fileregistry

import "github.com/sirkon/mpy6a/internal/types"

// NewLog создаёт дескриптор пустого лог-файла.
func (r *Registry) NewLog(id types.Index) *FileLog {
	r.stats.addFile()
	r.stats.Logs.Count++
	r.logs = append(r.logs, &logFile{
		id:    id,
		read:  0,
		write: 0,
	})

	return &FileLog{
		r:   r,
		log: r.logs[len(r.logs)-1],
	}
}

// NewSnapshot создаёт дескриптор только что созданного файла со слепком данных.
func (r *Registry) NewSnapshot(id types.Index, readArea uint64, size uint64) *FileSnapshot {
	r.stats.addFile()
	r.stats.addData(size)
	r.stats.Snapshots.Count++
	r.stats.Snapshots.Size += size
	r.snaps = append(r.snaps, &snapshotFile{
		id:       id,
		read:     0,
		readArea: readArea,
		size:     size,
	})

	return &FileSnapshot{
		r:    r,
		snap: r.snaps[len(r.snaps)-1],
	}
}

// NewMerge создаёт дескриптор только что созданного файла со слиянием.
func (r *Registry) NewMerge(id types.Index, read uint64, size uint64) *FileMerge {
	r.stats.addFile()
	r.stats.addData(size)
	r.stats.Merges.Count++
	r.stats.Merges.Size += size
	r.merges = append(r.merges, &mergeFile{
		id:   id,
		read: read,
		size: size,
	})

	return &FileMerge{
		r:     r,
		merge: r.merges[len(r.merges)-1],
	}
}

// NewFixed создаёт дескриптор пустого ФЗП файла.
func (r *Registry) NewFixed(id types.Index, delay int32) *FileFixed {
	r.stats.addFile()
	r.stats.Fixeds.Count++
	r.fixeds = append(r.fixeds, &fixedFile{
		id:    id,
		read:  0,
		write: 0,
		delay: delay,
	})

	return &FileFixed{
		r:     r,
		fixed: r.fixeds[len(r.fixeds)-1],
	}
}

// NewTemporary создаёт дескриптор временного файла.
func (r *Registry) NewTemporary(id types.Index) *FileTemporary {
	r.stats.addFile()
	r.stats.Temporaries++
	r.tmps = append(r.tmps, &tmpFile{
		id: id,
	})

	return &FileTemporary{
		r: r,
		t: r.tmps[len(r.tmps)-1],
	}
}
