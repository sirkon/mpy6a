package fileregistry

import "github.com/sirkon/mpy6a/internal/types"

// FileSnapshot контроллер работы с файлами слепков.
type FileSnapshot struct {
	r    *Registry
	snap *snapshotFile
}

// NextRead произошла вычитка c байт.
func (s *FileSnapshot) NextRead(c int) {
	s.snap.read += uint64(c)
}

// Remove перемещаем файл в неиспользуемые.
func (s *FileSnapshot) Remove(id types.Index) {
	s.r.removeSnap(s.snap)
	s.r.addUnused(fileRegistryUnusedFileTypeSnapshot, s.snap.id, id, s.snap.size, 0)
}

// Info возвращаем информацию о текущем файле слепка.
func (s *FileSnapshot) Info() (id types.Index, readPos uint64, readArea uint64, size uint64) {
	return s.snap.id, s.snap.read, s.snap.readArea, s.snap.size
}
