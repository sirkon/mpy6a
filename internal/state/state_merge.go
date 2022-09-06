package state

import (
	"io"
	"os"

	"github.com/sirkon/mpy6a/internal/errors"
	"golang.org/x/exp/maps"
)

// Подготовка к слиянию источников сессий.
func (s *State) prepareMerge() (res []func() (io.ReadCloser, error), err error) {
	s.rdl.Lock()
	defer s.rdl.Unlock()

	maps.Clear(s.descriptors.merges)
	maps.Clear(s.descriptors.snapshots)
	s.mgreader.reportState(s)

	n := len(s.descriptors.merges) + len(s.descriptors.snapshots)

	factor := n / s.limits.sources
	switch factor {
	case 0:
		// Слияние не требуется.
		return nil, nil
	case 1:
		// Требуется слияние до единственного источника.
		res = make([]func() (io.ReadCloser, error), n)

	default:

		// Требуется слияние до где factor уменьшится на 2.
		res = make([]func() (io.ReadCloser, error), 2*s.limits.sources)
	}

	snapshots := make([]*fileRangeDescriptor, 0, len(s.descriptors.snapshots))
	merges := make([]*fileRangeDescriptor, 0, len(s.descriptors.merges))
	for _, dsc := range s.descriptors.snapshots {
		snapshots = append(snapshots, dsc)
	}
	for _, dsc := range s.descriptors.merges {
		merges = append(merges, dsc)
	}

	for i := range res {
		// Проверяем, не закончились ли слепки. Если закончились,
		// то используем слияния.
		if i >= len(snapshots) {
			merge := merges[i-len(snapshots)]

			id := merge.id
			start := merge.start

			s.mgreader.underAsyncOp(id)
			res[i] = func() (_ io.ReadCloser, err error) {
				file, err := os.Open(s.mergedName(id))
				if err != nil {
					return nil, errors.Wrap(err, "open merge file")
				}

				defer func() {
					if err == nil {
						return
					}

					if err := file.Close(); err != nil {
						s.logger.Error(errors.Wrap(err, "Close merge file on termination"))
					}
				}()

				if _, err := file.Seek(int64(start), 0); err != nil {
					return nil, errors.Wrap(err, "seek in the merge file to the start")
				}

				return file, nil
			}

			continue
		}

		snap := snapshots[i]
		id := snap.id
		start := snap.start
		finish := snap.finish
		s.mgreader.underAsyncOp(id)
		res[i] = func() (io.ReadCloser, error) {
			file, err := os.Open(s.snapshotName(id))
			if err != nil {
				return nil, errors.Wrap(err, "open snapshot file")
			}

			defer func() {
				if err == nil {
					return
				}

				if err := file.Close(); err != nil {
					s.logger.Error(errors.Wrap(err, "Close snapshot file on termination"))
				}
			}()

			if _, err := file.Seek(int64(start), 0); err != nil {
				return nil, errors.Wrap(err, "seek in the snapshot file to the start")
			}

			return &limitFileReader{
				reader: io.LimitReader(file, int64(finish-start)),
				file:   file,
			}, nil
		}
	}

	s.descriptors.mergeIncoming = &fileRangeDescriptor{
		id: s.index,
	}

	return res, nil
}

type limitFileReader struct {
	reader io.Reader
	file   *os.File
}

func (l *limitFileReader) Read(p []byte) (n int, err error) {
	return l.reader.Read(p)
}

// Close для реализации io.ReadCloser
func (l *limitFileReader) Close() error {
	return l.file.Close()
}

type mergeIterator struct {
	srcs []io.ReadCloser
}
