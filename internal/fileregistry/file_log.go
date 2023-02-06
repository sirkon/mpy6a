package fileregistry

import "github.com/sirkon/mpy6a/internal/types"

// FileLog контроллер работы с файлами логов.
type FileLog struct {
	r   *Registry
	log *logFile
}

// NextRead произошла вычитка c байт.
func (l *FileLog) NextRead(c int) {
	l.log.read += uint64(c)
}

// NextWrite произошла запись c байт.
func (l *FileLog) NextWrite(c int, id types.Index) {
	if l.log.firstID.Term == 0 {
		l.log.firstID = id
	}
	l.log.lastID = id
	l.log.write += uint64(c)
	l.r.stats.TotalSize += uint64(c)
	l.r.stats.UsedSize += uint64(c)
	l.r.stats.Logs.Size += uint64(c)
}

// Remove перемещаем файл в неиспользуемые.
func (l *FileLog) Remove(id types.Index) {
	l.r.removeLog(l.log)
	l.r.addUnused(fileRegistryUnusedFileTypeLog, l.log.id, id, l.log.write, 0)
}

// Info возвращаем информацию о текущем файле лога.
func (l *FileLog) Info() (id types.Index, lastID types.Index, firstID types.Index, read uint64, write uint64) {
	return l.log.id, l.log.firstID, l.log.lastID, l.log.read, l.log.write
}
