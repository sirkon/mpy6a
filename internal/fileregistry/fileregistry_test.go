package fileregistry

import (
	"bytes"
	"fmt"
	"reflect"
	"testing"

	"github.com/sirkon/deepequal"
	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/testlog"
	"github.com/sirkon/mpy6a/internal/types"
)

func TestRegistryOps(t *testing.T) {
	type test struct {
		name string
		op   func(r *Registry)
		exp  func() *Registry
	}

	nid := types.NewIndex(10, 1)
	rid := types.NewIndex(11, 1)
	var log, snap, merge, fixed, tmp *Registry

	tests := []struct {
		group string
		tests []test
	}{
		{
			group: "adds and read/write ops",
			tests: []test{
				{
					name: "clone",
					op: func(r *Registry) {
						rr := r.Clone()
						copyRegistry(r, rr)
					},
					exp: sampleRegistry,
				},
				{
					name: "add new log and write + read in it",
					op: func(r *Registry) {
						l := r.NewLog(nid)
						l.NextWrite(5, types.NewIndex(1, 2), types.NewIndex(1, 2))
						l.NextRead(3)
						log = r
					},
					exp: func() *Registry {
						r := sampleRegistry()
						r.stats.FileCount++
						r.stats.FileUsed++
						r.stats.TotalSize += 5
						r.stats.UsedSize += 5
						r.stats.Logs.Count++
						r.stats.Logs.Size += 5
						r.logs = append(r.logs, &logFile{
							id:      nid,
							firstID: types.NewIndex(1, 2),
							lastID:  types.NewIndex(1, 2),
							read:    3,
							write:   5,
						})

						return r
					},
				},
				{
					name: "add new snapshot and read from it",
					op: func(r *Registry) {
						s := r.NewSnapshot(nid, 20, 40)
						s.NextRead(10)
						snap = r
					},
					exp: func() *Registry {
						r := sampleRegistry()
						r.stats.FileCount++
						r.stats.FileUsed++
						r.stats.UsedSize += 40
						r.stats.TotalSize += 40
						r.stats.Snapshots.Count++
						r.stats.Snapshots.Size += 40
						r.snaps = append(r.snaps, &snapshotFile{
							id:       nid,
							read:     10,
							readArea: 20,
							size:     40,
						})

						return r
					},
				},
				{
					name: "add new merge and read from it",
					op: func(r *Registry) {
						m := r.NewMerge(nid, 10, 20)
						m.NextRead(5)
						merge = r
					},
					exp: func() *Registry {
						r := sampleRegistry()
						r.stats.FileCount++
						r.stats.FileUsed++
						r.stats.UsedSize += 20
						r.stats.TotalSize += 20
						r.stats.Merges.Count++
						r.stats.Merges.Size += 20
						r.merges = append(r.merges, &mergeFile{
							id:   nid,
							read: 15,
							size: 20,
						})

						return r
					},
				},
				{
					name: "add new fixed and write + read in it",
					op: func(r *Registry) {
						f := r.NewFixed(nid, 40)
						f.NextWrite(60)
						f.NextRead(5)
						fixed = r
					},
					exp: func() *Registry {
						r := sampleRegistry()
						r.stats.FileCount++
						r.stats.FileUsed++
						r.stats.UsedSize += 60
						r.stats.TotalSize += 60
						r.stats.Fixeds.Count++
						r.stats.Fixeds.Size += 60
						r.fixeds = append(r.fixeds, &fixedFile{
							id:    nid,
							read:  5,
							write: 60,
							delay: 40,
						})

						return r
					},
				},
				{
					name: "add new temporary",
					op: func(r *Registry) {
						r.NewTemporary(nid)
						tmp = r
					},
					exp: func() *Registry {
						r := sampleRegistry()

						r.stats.FileCount++
						r.stats.FileUsed++
						r.stats.Temporaries++
						r.tmps = append(r.tmps, &tmpFile{id: nid})

						return r
					},
				},
			},
		},
		{
			group: "removes",
			tests: []test{
				{
					name: "remove log",
					op: func(r *Registry) {
						copyRegistry(r, log.Clone())
						l := r.Logs()[0]
						l.Remove(rid)
					},
					exp: func() *Registry {
						r := log.Clone()
						l := r.logs[0]
						r.logs = r.logs[1:]
						r.unused = append(r.unused, unusedFile{
							typ:      fileRegistryUnusedFileTypeLog,
							id:       l.id,
							lastUsed: rid,
							size:     l.write,
						})
						r.stats.FileUsed--
						r.stats.UsedSize -= l.write
						r.stats.Logs.Count--
						r.stats.Logs.Size -= l.write

						return r
					},
				},
				{
					name: "remove snapshot",
					op: func(r *Registry) {
						copyRegistry(r, snap.Clone())
						s := r.Snapshots()[0]
						s.Remove(rid)
					},
					exp: func() *Registry {
						r := snap.Clone()
						s := r.snaps[0]
						r.snaps = r.snaps[1:]
						r.unused = append(r.unused, unusedFile{
							typ:      fileRegistryUnusedFileTypeSnapshot,
							id:       s.id,
							lastUsed: rid,
							size:     s.size,
						})
						r.stats.FileUsed--
						r.stats.UsedSize -= s.size
						r.stats.Snapshots.Count--
						r.stats.Snapshots.Size -= s.size

						return r
					},
				},
				{
					name: "remove merge",
					op: func(r *Registry) {
						copyRegistry(r, merge.Clone())
						m := r.Merges()[0]
						m.Remove(rid)
					},
					exp: func() *Registry {
						r := merge.Clone()
						m := r.merges[0]
						r.merges = r.merges[1:]
						r.unused = append(r.unused, unusedFile{
							typ:      fileRegistryUnusedFileTypeMerge,
							id:       m.id,
							lastUsed: rid,
							size:     m.size,
						})
						r.stats.FileUsed--
						r.stats.UsedSize -= m.size
						r.stats.Merges.Count--
						r.stats.Merges.Size -= m.size

						return r
					},
				},
				{
					name: "remove fixed",
					op: func(r *Registry) {
						copyRegistry(r, fixed.Clone())
						r.Fixeds()[0].Remove(rid)
					},
					exp: func() *Registry {
						r := fixed.Clone()
						f := r.fixeds[0]
						r.fixeds = r.fixeds[1:]
						r.unused = append(r.unused, unusedFile{
							typ:      fileRegistryUnusedFileTypeFixed,
							id:       f.id,
							lastUsed: rid,
							size:     f.write,
							delay:    f.delay,
						})
						r.stats.FileUsed--
						r.stats.UsedSize -= f.write
						r.stats.Fixeds.Count--
						r.stats.Fixeds.Size -= f.write

						return r
					},
				},
				{
					name: "remove temporary",
					op: func(r *Registry) {
						copyRegistry(r, tmp.Clone())
						r.Temporaries()[0].Remove(rid)
					},
					exp: func() *Registry {
						r := tmp.Clone()
						t := r.tmps[0]
						r.tmps = r.tmps[1:]
						r.unused = append(r.unused, unusedFile{
							typ:      fileRegistryUnusedFileTypeTmp,
							id:       t.id,
							lastUsed: rid,
						})
						r.stats.FileUsed--
						r.stats.Temporaries--

						return r
					},
				},
				{
					name: "remove unused",
					op: func(r *Registry) {
						it := r.UnusedOld(types.NewIndex(0, 2))
						for it.Next() {
						}
						r.RemoveUnused(it)
					},
					exp: func() *Registry {
						r := sampleRegistry()
						u := r.unused[0]
						r.unused = r.unused[1:]
						r.stats.FileCount--
						r.stats.TotalSize -= u.size

						return r
					},
				},
			},
		},
		{
			group: "misc",
			tests: []test{
				{
					name: "temporary unreg",
					op: func(r *Registry) {
						t := r.Temporaries()[0]
						t.Unreg()
					},
					exp: func() *Registry {
						r := sampleRegistry()
						r.tmps = r.tmps[1:]
						r.stats.FileUsed--
						r.stats.FileCount--
						r.stats.Temporaries--

						return r
					},
				},
			},
		},
	}
	for _, g := range tests {
		t.Run(g.group, func(t *testing.T) {
			for _, tt := range g.tests {
				t.Run(tt.name, func(t *testing.T) {
					r := sampleRegistry()
					tt.op(r)
					e := tt.exp()

					if !deepequal.Equal(e, r) {
						t.Error("registries mismatch")
						deepequal.SideBySide(t, "file registries", e, r)
					}
				})
			}
		})
	}
}

func TestFileInfosAndStats(t *testing.T) {
	t.Run("stats", func(t *testing.T) {
		r := sampleRegistry()
		stats := r.Stats()

		if !deepequal.Equal(r.stats, stats) {
			t.Error("stats mismatch")
			deepequal.SideBySide(t, "stats", r.stats, stats)
		}
	})

	t.Run("log info", func(t *testing.T) {
		r := sampleRegistry()
		id, firstID, lastID, read, write := r.Logs()[0].Info()

		l := r.logs[0]
		const of = "log[0]"
		checkValue(t, "id", of, l.id, id)
		checkValue(t, "first id", of, l.firstID, firstID)
		checkValue(t, "last id", of, l.lastID, lastID)
		checkValue(t, "read", of, l.read, read)
		checkValue(t, "write", of, l.write, write)
	})

	t.Run("snapshot info", func(t *testing.T) {
		r := sampleRegistry()
		id, readPos, readArea, size := r.Snapshots()[0].Info()

		s := r.snaps[0]
		const of = "snap[0]"
		checkValue(t, "id", of, s.id, id)
		checkValue(t, "read position", of, s.read, readPos)
		checkValue(t, "read area", of, s.readArea, readArea)
		checkValue(t, "size", of, s.size, size)
	})

	t.Run("merge info", func(t *testing.T) {
		r := sampleRegistry()
		id, read, size := r.Merges()[0].Info()

		m := r.merges[0]
		const of = "merge[0]"
		checkValue(t, "id", of, m.id, id)
		checkValue(t, "read", of, m.read, read)
		checkValue(t, "size", of, m.size, size)
	})

	t.Run("fixed info", func(t *testing.T) {
		r := sampleRegistry()
		id, read, write, delay := r.Fixeds()[0].Info()

		f := r.fixeds[0]
		const of = "fixed[0]"
		checkValue(t, "id", of, f.id, id)
		checkValue(t, "read", of, f.read, read)
		checkValue(t, "write", of, f.write, write)
		checkValue(t, "delay", of, f.delay, delay)
	})

	t.Run("temporary info", func(t *testing.T) {
		r := sampleRegistry()
		id := r.Temporaries()[0].Info()

		tt := r.tmps[0]
		const of = "tmp[0]"
		checkValue(t, "id", of, tt.id, id)
	})

	t.Run("unused info", func(t *testing.T) {
		r := sampleRegistry()
		lud := r.unused[len(r.unused)-1].lastUsed
		it := r.UnusedOld(types.NewIndex(lud.Term+1, 1))

		type test struct {
			typ   fileRegistryUnusedFileType
			id    types.Index
			delay int32
		}
		values := []test{
			{
				typ:   r.unused[0].typ,
				id:    r.unused[0].id,
				delay: r.unused[0].delay,
			},
			{
				typ:   r.unused[1].typ,
				id:    r.unused[1].id,
				delay: r.unused[1].delay,
			},
		}
		var i int
		for it.Next() {
			v := values[i]
			of := fmt.Sprintf("unused[%d]", i)
			i++

			typ, id, delay := it.Info()
			checkValue(t, "type", of, v.typ, typ)
			checkValue(t, "id", of, v.id, id)
			checkValue(t, "delay", of, v.delay, delay)
		}
	})
}

func checkValue[T any](t *testing.T, what, of string, expected, actual T) {
	if deepequal.Equal(expected, actual) {
		return
	}

	t.Errorf("%s %v expected for %s, got %v", what, expected, of, actual)
}

func TestRegistryDumpRestore(t *testing.T) {
	var buf bytes.Buffer

	r := sampleRegistry()

	if err := r.Dump(&buf); err != nil {
		testlog.Error(t, errors.Wrap(err, "dump file registry"))
		return
	}

	nr, err := FromSnapshot(&buf)
	if err != nil {
		testlog.Error(t, errors.Wrap(err, "restore file registry"))
		return
	}

	if !reflect.DeepEqual(r, nr) {
		t.Error("value mismatch after the restore")
		deepequal.SideBySide(t, "file registries", r, nr)
	}
}

func TestSampleRegistry(t *testing.T) {
	expectedRegistry := &Registry{
		stats: Stats{
			FileCount: 7,
			FileUsed:  5,
			TotalSize: 11,
			UsedSize:  9,
			Logs: usedFilesInfo{
				Count: 1,
				Size:  2,
			},
			Snapshots: usedFilesInfo{
				Count: 1,
				Size:  3,
			},
			Merges: usedFilesInfo{
				Count: 1,
				Size:  2,
			},
			Fixeds: usedFilesInfo{
				Count: 1,
				Size:  2,
			},
			Temporaries: 1,
		},
		unused: []unusedFile{
			{
				typ:      fileRegistryUnusedFileTypeMerge,
				id:       types.NewIndex(1, 1),
				lastUsed: types.NewIndex(0, 1),
				size:     1,
			},
			{
				typ:      fileRegistryUnusedFileTypeFixed,
				id:       types.NewIndex(2, 1),
				lastUsed: types.NewIndex(1, 1),
				size:     1,
				delay:    15,
			},
		},
		logs: []*logFile{
			{
				id:      types.NewIndex(2, 1),
				firstID: types.NewIndex(2, 5),
				lastID:  types.NewIndex(14, 20),
				read:    1,
				write:   2,
			},
		},
		snaps: []*snapshotFile{
			{
				id:       types.NewIndex(3, 1),
				read:     1,
				readArea: 2,
				size:     3,
			},
		},
		merges: []*mergeFile{
			{
				id:   types.NewIndex(4, 1),
				read: 1,
				size: 2,
			},
		},
		fixeds: []*fixedFile{
			{
				id:    types.NewIndex(5, 1),
				read:  1,
				write: 2,
				delay: 16,
			},
		},
		tmps: []*tmpFile{
			{
				id: types.NewIndex(6, 1),
			},
		},
	}
	r := sampleRegistry()

	if !deepequal.Equal(expectedRegistry, r) {
		t.Error("sample and expected registries mismatch")
		deepequal.SideBySide(t, "file registries", expectedRegistry, r)
	}
}

func sampleRegistry() *Registry {
	r := New()

	log := r.NewLog(types.NewIndex(2, 1))
	log.NextWrite(2, types.NewIndex(2, 5), types.NewIndex(14, 20))
	log.NextRead(1)

	snap := r.NewSnapshot(types.NewIndex(3, 1), 2, 3)
	snap.NextRead(1)

	r.NewMerge(types.NewIndex(4, 1), 1, 2)

	fxd := r.NewFixed(types.NewIndex(5, 1), 16)
	fxd.NextWrite(2)
	fxd.NextRead(1)

	r.NewTemporary(types.NewIndex(6, 1))

	r.NewMerge(types.NewIndex(1, 1), 0, 1).Remove(types.NewIndex(0, 1))
	f1 := r.NewFixed(types.NewIndex(2, 1), 15)
	f1.NextWrite(1)
	f1.Remove(types.NewIndex(1, 1))

	return r
}

func copyRegistry(r, ar *Registry) {
	*r = *ar
}
