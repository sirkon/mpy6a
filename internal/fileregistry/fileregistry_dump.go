package fileregistry

import (
	"encoding/binary"
	"io"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/types"
)

// Dump сериализация и сохранение данных реестра.
// Формат:
//
//  1. Количество неиспользуемых файлов.
//  2. Данные неиспользуемых файлов.
//  3. Количество файлов логов.
//  4. Данные файлов логов.
//  5. Количество слепков.
//  6. Данные файлов слепков.
//  7. Количество файлов с фиксацией (интервала задержки повтора).
//  8. Данные файлов с фиксацией.
func (r *Registry) Dump(dst io.Writer) error {
	if err := r.dumpUnused(dst); err != nil {
		return errors.Wrap(err, "dump unused files")
	}

	if err := r.dumpLogs(dst); err != nil {
		return errors.Wrap(err, "dump log files")
	}

	if err := r.dumpSnapshots(dst); err != nil {
		return errors.Wrap(err, "dump snapshot files")
	}

	if err := r.dumpMerges(dst); err != nil {
		return errors.Wrap(err, "dump merge files")
	}

	if err := r.dumpFixeds(dst); err != nil {
		return errors.Wrap(err, "dump fixed repeat timeout files")
	}

	if err := r.dumpTemporaries(dst); err != nil {
		return errors.Wrap(err, "dump temporary files")
	}

	return nil
}

func (r *Registry) dumpUnused(dst io.Writer) error {
	l := len(r.unused)
	if err := dumpCount(dst, l); err != nil {
		return errors.Wrap(err, "dump files count")
	}

	for i, file := range r.unused {
		if err := dumpUnusedFile(dst, file); err != nil {
			return errors.Wrap(err, "dump file descriptor").
				Int("unused-file-index", i).
				Any("unused-file-value", file)
		}
	}

	return nil
}

func (r *Registry) dumpLogs(dst io.Writer) error {
	l := len(r.logs)
	if err := dumpCount(dst, l); err != nil {
		return errors.Wrap(err, "dump files count")
	}

	for i, log := range r.logs {
		if err := dumpLog(dst, log); err != nil {
			return errors.Wrap(err, "dump log descriptor").
				Int("log-file-index", i).
				Any("log-file-value", log)
		}
	}

	return nil
}

func (r *Registry) dumpSnapshots(dst io.Writer) error {
	l := len(r.snaps)
	if err := dumpCount(dst, l); err != nil {
		return errors.Wrap(err, "dump files count")
	}

	for i, snap := range r.snaps {
		if err := dumpSnapshot(dst, snap); err != nil {
			return errors.Wrap(err, "dump snapshot descriptor").
				Int("snapshot-file-index", i).
				Any("snapshot-file-value", snap)
		}
	}

	return nil
}

func (r *Registry) dumpMerges(dst io.Writer) error {
	l := len(r.merges)
	if err := dumpCount(dst, l); err != nil {
		return errors.Wrap(err, "dump files count")
	}

	for i, merge := range r.merges {
		if err := dumpMerge(dst, merge); err != nil {
			return errors.Wrap(err, "dump merge descriptor").
				Int("merge-file-index", i).
				Any("merge-file-value", merge)
		}
	}

	return nil
}

func (r *Registry) dumpFixeds(dst io.Writer) error {
	l := len(r.fixeds)

	if err := dumpCount(dst, l); err != nil {
		return errors.Wrap(err, "dump files count")
	}

	for i, fixed := range r.fixeds {
		if err := dumpFixed(dst, fixed); err != nil {
			return errors.Wrap(err, "dump fixed descriptor").
				Int("fixed-file-index", i).
				Any("fixed-file-value", fixed)
		}
	}

	return nil
}

func (r *Registry) dumpTemporaries(dst io.Writer) error {
	l := len(r.tmps)

	if err := dumpCount(dst, l); err != nil {
		return errors.Wrap(err, "dump files count")
	}

	for i, tmp := range r.tmps {
		if err := dumpTemporary(dst, tmp); err != nil {
			return errors.Wrap(err, "dump temporary descriptor").
				Int("temporary-file-index", i).
				Any("temporary-file-value", tmp)
		}
	}

	return nil
}

func dumpUnusedFile(dst io.Writer, f unusedFile) error {
	if err := dumpInt32(dst, int32(f.typ)); err != nil {
		return errors.Wrap(err, "dump file type")
	}

	if err := dumpID(dst, f.id); err != nil {
		return errors.Wrap(err, "dump id")
	}

	if err := dumpID(dst, f.lastUsed); err != nil {
		return errors.Wrap(err, "dump id of removal")
	}

	if err := dumpUint64(dst, f.size); err != nil {
		return errors.Wrap(err, "dump file size")
	}

	if f.typ == fileRegistryUnusedFileTypeFixed {
		if err := dumpInt32(dst, f.delay); err != nil {
			return errors.Wrap(err, "size repeat delay")
		}
	}

	return nil
}

func dumpLog(dst io.Writer, l *logFile) error {
	if err := dumpID(dst, l.id); err != nil {
		return errors.Wrap(err, "dump id")
	}

	if err := dumpID(dst, l.firstID); err != nil {
		return errors.Wrap(err, "dump first id")
	}

	if err := dumpID(dst, l.lastID); err != nil {
		return errors.Wrap(err, "dump last id")
	}

	if err := dumpUint64(dst, l.read); err != nil {
		return errors.Wrap(err, "dump read position")
	}

	if err := dumpUint64(dst, l.write); err != nil {
		return errors.Wrap(err, "dump size position")
	}

	return nil
}

func dumpSnapshot(dst io.Writer, s *snapshotFile) error {
	if err := dumpID(dst, s.id); err != nil {
		return errors.Wrap(err, "dump id")
	}

	if err := dumpUint64(dst, s.read); err != nil {
		return errors.Wrap(err, "dump read position")
	}

	if err := dumpUint64(dst, s.readArea); err != nil {
		return errors.Wrap(err, "dump total read size")
	}

	if err := dumpUint64(dst, s.size); err != nil {
		return errors.Wrap(err, "dump total size")
	}

	return nil
}

func dumpMerge(dst io.Writer, s *mergeFile) error {
	if err := dumpID(dst, s.id); err != nil {
		return errors.Wrap(err, "dump id")
	}

	if err := dumpUint64(dst, s.read); err != nil {
		return errors.Wrap(err, "dump read position")
	}

	if err := dumpUint64(dst, s.size); err != nil {
		return errors.Wrap(err, "dump size")
	}

	return nil

}

func dumpFixed(dst io.Writer, f *fixedFile) error {
	if err := dumpID(dst, f.id); err != nil {
		return errors.Wrap(err, "dump id")
	}

	if err := dumpUint64(dst, f.read); err != nil {
		return errors.Wrap(err, "dump read position")
	}

	if err := dumpUint64(dst, f.write); err != nil {
		return errors.Wrap(err, "dump size position")
	}

	if err := dumpInt32(dst, f.delay); err != nil {
		return errors.Wrap(err, "dump repeat delay")
	}

	return nil
}

func dumpTemporary(dst io.Writer, r *tmpFile) error {
	if err := dumpID(dst, r.id); err != nil {
		return errors.Wrap(err, "dump id")
	}

	return nil
}

func dumpCount(dst io.Writer, count int) error {
	var buf [16]byte
	l := binary.PutUvarint(buf[:], uint64(count))

	if _, err := dst.Write(buf[:l]); err != nil {
		return err
	}

	return nil
}

func dumpID(dst io.Writer, id types.Index) error {
	var buf [16]byte

	types.IndexEncode(buf[:], id)
	if _, err := dst.Write(buf[:]); err != nil {
		return err
	}

	return nil
}

func dumpUint64(dst io.Writer, v uint64) error {
	var buf [8]byte

	binary.LittleEndian.PutUint64(buf[:], v)
	if _, err := dst.Write(buf[:]); err != nil {
		return err
	}

	return nil
}

func dumpInt32(dst io.Writer, v int32) error {
	var buf [4]byte

	binary.LittleEndian.PutUint32(buf[:], uint32(v))
	if _, err := dst.Write(buf[:]); err != nil {
		return err
	}

	return nil
}
