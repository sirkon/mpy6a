package fileregistry

import "github.com/sirkon/mpy6a/internal/types"

// FileMerge контроллер работы с файлами слияний.
type FileMerge struct {
	r     *Registry
	merge *mergeFile
}

// NextRead произошла вычитка c байт.
func (m *FileMerge) NextRead(c int) {
	m.merge.read += uint64(c)
}

// Remove перемещаем файл в неиспользуемые.
func (m *FileMerge) Remove(id types.Index) {
	m.r.removeMerge(m.merge)
	m.r.addUnused(fileRegistryUnusedFileTypeMerge, m.merge.id, id, m.merge.size, 0)
}

// Info возвращаем информацию о текущем файле слияния.
func (m *FileMerge) Info() (id types.Index, read uint64, size uint64) {
	return m.merge.id, m.merge.read, m.merge.size
}
