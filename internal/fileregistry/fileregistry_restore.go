package fileregistry

import (
	"encoding/binary"
	"io"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/types"
)

// Reader требования на читалку, этому удовлетворяет bufio.Reader,
// например.
type Reader interface {
	io.ByteReader
	io.Reader
}

// FromSnapshot восстановление реестра файлов из куска слепка.
func FromSnapshot(src Reader) (*Registry, error) {
	var r Registry

	if err := restoreUnuseds(&r, src); err != nil {
		return nil, errors.Wrap(err, "restore unused files descriptors")
	}

	if err := restoreLogs(&r, src); err != nil {
		return nil, errors.Wrap(err, "restore log files descriptors")
	}

	if err := restoreSnaps(&r, src); err != nil {
		return nil, errors.Wrap(err, "restore snapshot files descriptors")
	}

	if err := restoreMerges(&r, src); err != nil {
		return nil, errors.Wrap(err, "restore merge files descriptors")
	}

	if err := restoreFixeds(&r, src); err != nil {
		return nil, errors.Wrap(err, "restore fixed files descriptors")
	}

	if err := restoreTemporaries(&r, src); err != nil {
		return nil, errors.Wrap(err, "restore temporary files descriptors")
	}

	return &r, nil
}

func restoreUnuseds(r *Registry, src Reader) error {
	l, err := restoreCount(src)
	if err != nil {
		return errors.Wrap(err, "get count of files")
	}

	r.unused = make([]unusedFile, l)
	for i := range r.unused {
		unused, err := restoreUnused(src)
		if err != nil {
			return errors.Wrap(err, "restore unused file descriptor").
				Int("unused-file-index", i).
				Int("unused-files-count", l)
		}

		r.unused[i] = unused

		r.stats.FileCount++
		r.stats.TotalSize += unused.size
	}

	return nil
}

func restoreLogs(r *Registry, src Reader) error {
	l, err := restoreCount(src)
	if err != nil {
		return errors.Wrap(err, "get count of files")
	}

	r.logs = make([]*logFile, l)
	for i := range r.logs {
		log, err := restoreLog(src)
		if err != nil {
			return errors.Wrap(err, "restore log file descriptor").
				Int("log-file-index", i).
				Int("log-files-count", l)
		}

		r.logs[i] = log
		r.stats.FileCount++
		r.stats.FileUsed++
		r.stats.TotalSize += log.write
		r.stats.UsedSize += log.write
		r.stats.Logs.Count++
		r.stats.Logs.Size += log.write
	}

	return nil
}

func restoreSnaps(r *Registry, src Reader) error {
	l, err := restoreCount(src)
	if err != nil {
		return errors.Wrap(err, "get count of files")
	}

	r.snaps = make([]*snapshotFile, l)
	for i := range r.snaps {
		snap, err := restoreSnap(src)
		if err != nil {
			return errors.Wrap(err, "restore snapshot file descriptor").
				Int("snapshot-file-index", i).
				Int("snapshot-files-count", l)
		}

		r.snaps[i] = snap
		r.stats.FileCount++
		r.stats.FileUsed++
		r.stats.TotalSize += snap.size
		r.stats.UsedSize += snap.size
		r.stats.Snapshots.Count++
		r.stats.Snapshots.Size += snap.size
	}

	return nil
}

func restoreMerges(r *Registry, src Reader) error {
	l, err := restoreCount(src)
	if err != nil {
		return errors.Wrap(err, "get count of files")
	}

	r.merges = make([]*mergeFile, l)
	for i := range r.merges {
		merge, err := restoreMerge(src)
		if err != nil {
			return errors.Wrap(err, "restore merge file descriptor").
				Int("merge-file-index", i).
				Int("merge-files-count", l)
		}

		r.merges[i] = merge
		r.stats.FileCount++
		r.stats.FileUsed++
		r.stats.TotalSize += merge.size
		r.stats.UsedSize += merge.size
		r.stats.Merges.Count++
		r.stats.Merges.Size += merge.size
	}

	return nil
}

func restoreFixeds(r *Registry, src Reader) error {
	l, err := restoreCount(src)
	if err != nil {
		return errors.Wrap(err, "get count of files")
	}

	r.fixeds = make([]*fixedFile, l)
	for i := range r.fixeds {
		fixed, err := restoreFixed(src)
		if err != nil {
			return errors.Wrap(err, "restore fixed repeat timeout file descriptor").
				Int("fixed-file-index", i).
				Int("fixed-files-count", l)
		}

		r.fixeds[i] = fixed
		r.stats.FileCount++
		r.stats.FileUsed++
		r.stats.TotalSize += fixed.write
		r.stats.UsedSize += fixed.write
		r.stats.Fixeds.Count++
		r.stats.Fixeds.Size += fixed.write
	}

	return nil
}

func restoreTemporaries(r *Registry, src Reader) error {
	l, err := restoreCount(src)
	if err != nil {
		return errors.Wrap(err, "get count of files")
	}

	r.tmps = make([]*tmpFile, l)
	for i := range r.tmps {
		tmp, err := restoreTemporary(src)
		if err != nil {
			return errors.Wrap(err, "restore temporary file")
		}

		r.tmps[i] = tmp
		r.stats.FileCount++
		r.stats.FileUsed++
		r.stats.Temporaries++
	}

	return nil
}

func restoreUnused(src Reader) (res unusedFile, _ error) {
	var buf [4]byte
	if _, err := io.ReadFull(src, buf[:]); err != nil {
		return res, errors.Wrap(err, "read file type info")
	}
	res.typ = fileRegistryUnusedFileType(binary.LittleEndian.Uint32(buf[:]))

	id, err := restoreID(src)
	if err != nil {
		return res, errors.Wrap(err, "read file id")
	}
	res.id = id

	lastID, err := restoreID(src)
	if err != nil {
		return res, errors.Wrap(err, "read last usage id")
	}
	res.lastUsed = lastID

	size, err := restoreUint64(src)
	if err != nil {
		return res, errors.Wrap(err, "restore file size info")
	}
	res.size = size

	if res.typ == fileRegistryUnusedFileTypeFixed {
		delay, err := restoreInt32(src)
		if err != nil {
			return res, errors.Wrap(err, "restore repeat delay")
		}

		res.delay = delay
	}

	return res, nil
}

func restoreLog(src Reader) (*logFile, error) {
	id, err := restoreID(src)
	if err != nil {
		return nil, errors.Wrap(err, "read file id")
	}

	read, err := restoreUint64(src)
	if err != nil {
		return nil, errors.Wrap(err, "read read position")
	}

	write, err := restoreUint64(src)
	if err != nil {
		return nil, errors.Wrap(err, "read size position")
	}

	res := &logFile{
		id:    id,
		read:  read,
		write: write,
	}
	return res, nil
}

func restoreSnap(src Reader) (*snapshotFile, error) {
	id, err := restoreID(src)
	if err != nil {
		return nil, errors.Wrap(err, "read file id")
	}

	read, err := restoreUint64(src)
	if err != nil {
		return nil, errors.Wrap(err, "read read position")
	}

	readSize, err := restoreUint64(src)
	if err != nil {
		return nil, errors.Wrap(err, "read read size")
	}

	size, err := restoreUint64(src)
	if err != nil {
		return nil, errors.Wrap(err, "read size")
	}

	res := &snapshotFile{
		id:       id,
		read:     read,
		readArea: readSize,
		size:     size,
	}
	return res, nil
}

func restoreMerge(src Reader) (*mergeFile, error) {
	id, err := restoreID(src)
	if err != nil {
		return nil, errors.Wrap(err, "read file id")
	}

	read, err := restoreUint64(src)
	if err != nil {
		return nil, errors.Wrap(err, "read read position")
	}

	size, err := restoreUint64(src)
	if err != nil {
		return nil, errors.Wrap(err, "read size")
	}

	res := &mergeFile{
		id:   id,
		read: read,
		size: size,
	}
	return res, nil
}

func restoreFixed(src Reader) (*fixedFile, error) {
	id, err := restoreID(src)
	if err != nil {
		return nil, errors.Wrap(err, "read file id")
	}

	read, err := restoreUint64(src)
	if err != nil {
		return nil, errors.Wrap(err, "read read position")
	}

	write, err := restoreUint64(src)
	if err != nil {
		return nil, errors.Wrap(err, "read size position")
	}

	delay, err := restoreInt32(src)
	if err != nil {
		return nil, errors.Wrap(err, "read delay")
	}

	res := &fixedFile{
		id:    id,
		read:  read,
		write: write,
		delay: delay,
	}
	return res, nil
}

func restoreTemporary(src Reader) (*tmpFile, error) {
	id, err := restoreID(src)
	if err != nil {
		return nil, errors.Wrap(err, "read file id")
	}

	return &tmpFile{
		id: id,
	}, nil
}

func restoreCount(src Reader) (int, error) {
	res, err := binary.ReadUvarint(src)
	if err != nil {
		return 0, err
	}

	return int(res), nil
}

func restoreID(src Reader) (types.Index, error) {
	var buf [16]byte
	if _, err := io.ReadFull(src, buf[:]); err != nil {
		return types.Index{}, err
	}

	return types.IndexDecode(buf[:]), nil
}

func restoreUint64(src Reader) (uint64, error) {
	var buf [8]byte
	if _, err := io.ReadFull(src, buf[:]); err != nil {
		return 0, err
	}

	return binary.LittleEndian.Uint64(buf[:]), nil
}

func restoreInt32(src Reader) (int32, error) {
	var buf [4]byte

	if _, err := io.ReadFull(src, buf[:]); err != nil {
		return 0, err
	}

	return int32(binary.LittleEndian.Uint32(buf[:])), nil
}
