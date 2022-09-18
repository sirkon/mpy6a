package fileregistry

import "github.com/sirkon/mpy6a/internal/types"

func (r *Registry) removeLog(log *logFile) {
	for i, file := range r.logs {
		if file == log {
			r.stats.Logs.Count--
			r.stats.Logs.Size -= log.write
			r.logs = append(r.logs[:i], r.logs[i+1:]...)
			return
		}
	}
}

func (r *Registry) removeSnap(snap *snapshotFile) {
	for i, file := range r.snaps {
		if file == snap {
			r.stats.Snapshots.Count--
			r.stats.Snapshots.Size -= snap.size
			r.snaps = append(r.snaps[:i], r.snaps[i+1:]...)
			return
		}
	}
}

func (r *Registry) removeMerge(merge *mergeFile) {
	for i, file := range r.merges {
		if file == merge {
			r.stats.Merges.Count--
			r.stats.Merges.Size -= merge.size
			r.merges = append(r.merges[:i], r.merges[i+1:]...)
			return
		}
	}
}

func (r *Registry) removeFixed(fixed *fixedFile) {
	for i, file := range r.fixeds {
		if file == fixed {
			r.fixeds = append(r.fixeds[:i], r.fixeds[i+1:]...)
			r.stats.Fixeds.Count--
			r.stats.Fixeds.Size -= fixed.write
			return
		}
	}
}

func (r *Registry) removeTemporary(tmp *tmpFile) {
	for i, file := range r.tmps {
		if file == tmp {
			r.stats.Temporaries--
			r.tmps = append(r.tmps[:i], r.tmps[i+1:]...)
			return
		}
	}
}

func (r *Registry) addUnused(typ fileRegistryUnusedFileType, id, lastID types.Index, size uint64, delay int32) {
	r.stats.UsedSize -= size
	r.stats.FileUsed--

	r.unused = append(r.unused, unusedFile{
		typ:      typ,
		id:       id,
		lastUsed: lastID,
		size:     size,
		delay:    delay,
	})
}
