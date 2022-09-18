package fileregistry

import "github.com/sirkon/mpy6a/internal/types"

// FileFixed контроллер работы с файлами сохранений с фиксированным ожиданием повтора.
type FileFixed struct {
	r     *Registry
	fixed *fixedFile
}

// NextRead произошла вычитка c байт.
func (l *FileFixed) NextRead(c int) {
	l.fixed.read += uint64(c)
}

// NextWrite произошла запись c байт.
func (l *FileFixed) NextWrite(c int) {
	l.fixed.write += uint64(c)
	l.r.stats.TotalSize += uint64(c)
	l.r.stats.UsedSize += uint64(c)
	l.r.stats.Fixeds.Size += uint64(c)
}

// Remove перемещаем файл в неиспользуемые.
func (l *FileFixed) Remove(id types.Index) {
	l.r.removeFixed(l.fixed)
	l.r.addUnused(fileRegistryUnusedFileTypeFixed, l.fixed.id, id, l.fixed.write, l.fixed.delay)
}

// Info возвращаем информацию о текущем ФЗП файле.
func (l *FileFixed) Info() (id types.Index, read uint64, write uint64, delay int32) {
	return l.fixed.id, l.fixed.read, l.fixed.write, l.fixed.delay
}
