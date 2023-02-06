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
func (r *Registry) Dump(dst io.Writer) (int, error) {
	uc, err := r.dumpUnused(dst)
	if err != nil {
		return 0, errors.Wrap(err, "dump unused files")
	}

	lc, err := r.dumpLogs(dst)
	if err != nil {
		return 0, errors.Wrap(err, "dump log files")
	}

	sc, err := r.dumpSnapshots(dst)
	if err != nil {
		return 0, errors.Wrap(err, "dump snapshot files")
	}

	mc, err := r.dumpMerges(dst)
	if err != nil {
		return 0, errors.Wrap(err, "dump merge files")
	}

	fc, err := r.dumpFixeds(dst)
	if err != nil {
		return 0, errors.Wrap(err, "dump fixed repeat timeout files")
	}

	tc, err := r.dumpTemporaries(dst)
	if err != nil {
		return 0, errors.Wrap(err, "dump temporary files")
	}

	return uc + lc + sc + mc + fc + tc, nil
}

func (r *Registry) dumpUnused(dst io.Writer) (int, error) {
	l := len(r.unused)
	res, err := dumpCount(dst, l)
	if err != nil {
		return 0, errors.Wrap(err, "dump files count")
	}

	for i, file := range r.unused {
		uc, err := dumpUnusedFile(dst, file)
		if err != nil {
			return 0, errors.Wrap(err, "dump file descriptor").
				Int("unused-file-index", i).
				Any("unused-file-value", file)
		}
		res += uc
	}

	return res, nil
}

func (r *Registry) dumpLogs(dst io.Writer) (int, error) {

	l := len(r.logs)
	res, err := dumpCount(dst, l)
	if err != nil {
		return 0, errors.Wrap(err, "dump files count")
	}

	for i, log := range r.logs {
		lc, err := dumpLog(dst, log)
		if err != nil {
			return 0, errors.Wrap(err, "dump log descriptor").
				Int("log-file-index", i).
				Any("log-file-value", log)
		}

		res += lc
	}

	return res, nil
}

func (r *Registry) dumpSnapshots(dst io.Writer) (int, error) {
	l := len(r.snaps)
	res, err := dumpCount(dst, l)
	if err != nil {
		return 0, errors.Wrap(err, "dump files count")
	}

	for i, snap := range r.snaps {
		dc, err := dumpSnapshot(dst, snap)
		if err != nil {
			return 0, errors.Wrap(err, "dump snapshot descriptor").
				Int("snapshot-file-index", i).
				Any("snapshot-file-value", snap)
		}
		res += dc
	}

	return res, nil
}

func (r *Registry) dumpMerges(dst io.Writer) (int, error) {

	l := len(r.merges)
	res, err := dumpCount(dst, l)
	if err != nil {
		return 0, errors.Wrap(err, "dump files count")
	}

	for i, merge := range r.merges {
		mc, err := dumpMerge(dst, merge)
		if err != nil {
			return 0, errors.Wrap(err, "dump merge descriptor").
				Int("merge-file-index", i).
				Any("merge-file-value", merge)
		}
		res += mc
	}

	return res, nil
}

func (r *Registry) dumpFixeds(dst io.Writer) (int, error) {
	l := len(r.fixeds)

	res, err := dumpCount(dst, l)
	if err != nil {
		return 0, errors.Wrap(err, "dump files count")
	}

	for i, fixed := range r.fixeds {
		fc, err := dumpFixed(dst, fixed)
		if err != nil {
			return 0, errors.Wrap(err, "dump fixed descriptor").
				Int("fixed-file-index", i).
				Any("fixed-file-value", fixed)
		}
		res += fc
	}

	return res, nil
}

func (r *Registry) dumpTemporaries(dst io.Writer) (int, error) {
	l := len(r.tmps)

	res, err := dumpCount(dst, l)
	if err != nil {
		return 0, errors.Wrap(err, "dump files count")
	}

	for i, tmp := range r.tmps {
		tc, err := dumpTemporary(dst, tmp)
		if err != nil {
			return 0, errors.Wrap(err, "dump temporary descriptor").
				Int("temporary-file-index", i).
				Any("temporary-file-value", tmp)
		}
		res += tc
	}

	return res, nil
}

func dumpUnusedFile(dst io.Writer, f unusedFile) (int, error) {
	if err := dumpInt32(dst, int32(f.typ)); err != nil {
		return 0, errors.Wrap(err, "dump file type")
	}

	if err := dumpID(dst, f.id); err != nil {
		return 0, errors.Wrap(err, "dump id")
	}

	if err := dumpID(dst, f.lastUsed); err != nil {
		return 0, errors.Wrap(err, "dump id of removal")
	}

	if err := dumpUint64(dst, f.size); err != nil {
		return 0, errors.Wrap(err, "dump file size")
	}

	res := 44

	if f.typ == fileRegistryUnusedFileTypeFixed {
		res = 48
		if err := dumpInt32(dst, f.delay); err != nil {
			return 0, errors.Wrap(err, "size repeat delay")
		}
	}

	return res, nil
}

func dumpLog(dst io.Writer, l *logFile) (int, error) {
	if err := dumpID(dst, l.id); err != nil {
		return 0, errors.Wrap(err, "dump id")
	}

	if err := dumpID(dst, l.firstID); err != nil {
		return 0, errors.Wrap(err, "dump first id")
	}

	if err := dumpID(dst, l.lastID); err != nil {
		return 0, errors.Wrap(err, "dump last id")
	}

	if err := dumpUint64(dst, l.read); err != nil {
		return 0, errors.Wrap(err, "dump read position")
	}

	if err := dumpUint64(dst, l.write); err != nil {
		return 0, errors.Wrap(err, "dump size position")
	}

	return 64, nil
}

func dumpSnapshot(dst io.Writer, s *snapshotFile) (int, error) {
	if err := dumpID(dst, s.id); err != nil {
		return 0, errors.Wrap(err, "dump id")
	}

	if err := dumpUint64(dst, s.read); err != nil {
		return 0, errors.Wrap(err, "dump read position")
	}

	if err := dumpUint64(dst, s.readArea); err != nil {
		return 0, errors.Wrap(err, "dump total read size")
	}

	if err := dumpUint64(dst, s.size); err != nil {
		return 0, errors.Wrap(err, "dump total size")
	}

	return 40, nil
}

func dumpMerge(dst io.Writer, s *mergeFile) (int, error) {
	if err := dumpID(dst, s.id); err != nil {
		return 0, errors.Wrap(err, "dump id")
	}

	if err := dumpUint64(dst, s.read); err != nil {
		return 0, errors.Wrap(err, "dump read position")
	}

	if err := dumpUint64(dst, s.size); err != nil {
		return 0, errors.Wrap(err, "dump size")
	}

	return 32, nil

}

func dumpFixed(dst io.Writer, f *fixedFile) (int, error) {
	if err := dumpID(dst, f.id); err != nil {
		return 0, errors.Wrap(err, "dump id")
	}

	if err := dumpUint64(dst, f.read); err != nil {
		return 0, errors.Wrap(err, "dump read position")
	}

	if err := dumpUint64(dst, f.write); err != nil {
		return 0, errors.Wrap(err, "dump size position")
	}

	if err := dumpInt32(dst, f.delay); err != nil {
		return 0, errors.Wrap(err, "dump repeat delay")
	}

	return 36, nil
}

func dumpTemporary(dst io.Writer, r *tmpFile) (int, error) {
	if err := dumpID(dst, r.id); err != nil {
		return 0, errors.Wrap(err, "dump id")
	}

	return 16, nil
}

func dumpCount(dst io.Writer, count int) (int, error) {
	var buf [16]byte
	l := binary.PutUvarint(buf[:], uint64(count))

	if _, err := dst.Write(buf[:l]); err != nil {
		return 0, err
	}

	return l, nil
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
