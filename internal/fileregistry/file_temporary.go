package fileregistry

import "github.com/sirkon/mpy6a/internal/types"

// FileTemporary контроллер работы с временными файлами.
type FileTemporary struct {
	r *Registry
	t *tmpFile
}

// Remove перемещаем файл в неиспользуемые. Эта операция соответствует
// неудачному заполнению временного файла, когда это не удалось произвести.
// В таком случае необходимо удалить временный файл.
func (t *FileTemporary) Remove(id types.Index) {
	t.r.removeTemporary(t.t)
	t.r.addUnused(fileRegistryUnusedFileTypeTmp, t.t.id, id, 0, 0)
}

// Unreg снимаем временный файл с регистрации. Эта операция
// соответствует переименованию временного файла в постоянный
// какого-то фиксированного типа.
func (t *FileTemporary) Unreg() {
	t.r.stats.FileCount--
	t.r.stats.FileUsed--
	t.r.removeTemporary(t.t)
}

// Info возвращаем информацию о текущем временном файле.
func (t *FileTemporary) Info() (id types.Index) {
	return t.t.id
}
