package state

import (
	"bufio"
	"encoding/binary"
	"os"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/types"
	"github.com/sirkon/mpy6a/internal/uvarints"
)

// Создание слепка данного состояния. Предполагается, что
// слепок делается из клона действительного состояния.
func (s *State) snapshot() (err error) {
	// Открываем файл для записи.
	file, err := os.Create(s.snapshotName(s.index))
	if err != nil {
		return errors.Wrap(err, "create snapshot file")
	}

	defer func() {
		if err != nil {
			return
		}

		err = file.Close()
		if err != nil {
			err = errors.Wrap(err, "Close just filled snapshot file")
		}
	}()

	dst := bufio.NewWriter(file)
	defer func() {
		if err != nil {
			return
		}

		err = dst.Flush()
		if err != nil {
			err = errors.Wrap(err, "flush buffer into the snapshot")
		}
	}()

	if err := s.snapshotSavedData(dst); err != nil {
		return errors.Wrap(err, "dump saved sessions")
	}

	if err := s.snapshotActiveSessions(dst); err != nil {
		return errors.Wrap(err, "dump active sessions")
	}

	// Сохраняем индекс состояния и дескрипторы.
	if err := s.snapshotIndexAndDescriptors(dst); err != nil {
		return errors.Wrap(err, "dump state index and files descriptors")
	}

	return nil
}

func (s *State) snapshotSavedData(dst *bufio.Writer) error {
	// Вычисляем длину данных сохранённых в памяти сессий.
	var savedLength uint64
	iter := s.saved.tree.Iter()
	for iter.Next() {
		item := iter.Item()
		for _, sd := range item.Sessions {
			savedLength += 8 + uint64(uvarints.LengthInt(uint64(len(sd)))) + uint64(len(sd))
		}
	}

	// Пишем вычисленную длину.
	var buf [16]byte
	binary.LittleEndian.PutUint64(buf[:8], savedLength)
	if _, err := dst.Write(buf[:8]); err != nil {
		return errors.Wrap(err, "push saved sessions length")
	}

	// Пишем сами данные сессий.
	iter = s.saved.tree.Iter()
	for iter.Next() {
		item := iter.Item()

		for _, sd := range item.Sessions {
			binary.LittleEndian.PutUint64(buf[:8], item.Repeat)
			if _, err := dst.Write(buf[:8]); err != nil {
				return errors.Wrap(err, "push Session repeat time")
			}

			l := binary.PutUvarint(buf[:16], uint64(len(sd)))
			if _, err := dst.Write(buf[:l]); err != nil {
				return errors.Wrap(err, "push Session data length")
			}

			if _, err := dst.Write(sd); err != nil {
				return errors.Wrap(err, "push Session data")
			}
		}
	}

	return nil
}

func (s *State) snapshotActiveSessions(dst *bufio.Writer) error {
	// Вычисляем длину данных активных сессий.
	var activeLength uint64
	for _, s := range s.active {
		activeLength += uint64(s.storageLen())
	}
	activeLength -= 8 * uint64(len(s.active)) // Нам не нужно время повтора здесь

	var buf [16]byte
	binary.LittleEndian.PutUint64(buf[:8], activeLength)

	if _, err := dst.Write(buf[:8]); err != nil {
		return errors.Wrap(err, "push active sessions length")
	}

	for _, ss := range s.active {
		encdata := s.encodeSession(ss)

		l := binary.PutUvarint(buf[:16], uint64(len(encdata)))
		if _, err := dst.Write(buf[:l]); err != nil {
			return errors.Wrap(err, "push Session data length")
		}

		if _, err := dst.Write(encdata); err != nil {
			return errors.Wrap(err, "push Session data")
		}
	}

	return nil
}

func (s *State) snapshotIndexAndDescriptors(dst *bufio.Writer) error {
	// Пишем индекс состояния.
	var tmp [16]byte
	s.index.encode(tmp[:16])
	if _, err := dst.Write(tmp[:16]); err != nil {
		return errors.Wrap(err, "dump state index")
	}

	if err := s.dumpDescriptorClass(dst, s.descriptors.snapshots); err != nil {
		return errors.Wrap(err, "dump snapshots descriptors")
	}

	if err := s.dumpDescriptorClass(dst, s.descriptors.merges); err != nil {
		return errors.Wrap(err, "dump merges descriptors")
	}

	if err := s.dumpDescriptorClass(dst, s.descriptors.fixedTimeouts); err != nil {
		return errors.Wrap(err, "dump fixed timeouts descriptors")
	}

	if err := s.dumpLogs(dst); err != nil {
		return errors.Wrap(err, "dump logs descriptors")
	}

	return nil
}

func (s *State) dumpDescriptorClass(dst *bufio.Writer, class map[types.Index]*fileRangeDescriptor) error {
	var (
		tmp [32]byte
	)

	l := binary.PutUvarint(tmp[:16], uint64(len(class)))
	if _, err := dst.Write(tmp[:l]); err != nil {
		return errors.Wrap(err, "dump descriptors count")
	}

	for id, dsc := range class {
		id.encode(tmp[:16])
		binary.LittleEndian.PutUint64(tmp[16:], dsc.start)
		binary.LittleEndian.PutUint64(tmp[24:], dsc.finish)
		if _, err := dst.Write(tmp[:32]); err != nil {
			return errors.Wrap(err, "dump descriptor").Stg("failed-descriptor-id", id)
		}
	}

	return nil
}

func (s *State) dumpLogs(dst *bufio.Writer) error {
	var tmp [32]byte

	l := binary.PutUvarint(tmp[:16], uint64(len(s.descriptors.logs)))
	if _, err := dst.Write(tmp[:l]); err != nil {
		return errors.Wrap(err, "push logs count")
	}

	for i, log := range s.descriptors.logs {
		log.id.encode(tmp[:16])
		log.last.encode(tmp[16:32])
		if _, err := dst.Write(tmp[:32]); err != nil {
			return errors.Wrapf(err, "push log index %d", i)
		}
	}

	return nil
}
