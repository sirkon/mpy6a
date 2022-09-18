package fileregistry

import "github.com/sirkon/mpy6a/internal/types"

// UnusedOld возвращает итератор по неиспользуемым файлам использовавшимися
// в последний раз до момента lastID. Описания неиспользуемых файлов
// натуральным образом упорядочены по идентификатору последнего использования.
func (r *Registry) UnusedOld(lastID types.Index) *UnusedIterator {
	return &UnusedIterator{
		r:      r,
		i:      0,
		lastID: lastID,
	}
}

// UnusedIterator итератор по неиспользуемым файлам.
type UnusedIterator struct {
	r      *Registry
	i      int
	lastID types.Index

	stat Stats
}

// Next проверка, есть ли ещё искомые файлы.
func (i *UnusedIterator) Next() bool {
	if i.i >= len(i.r.unused) {
		return false
	}

	if !types.IndexLess(i.r.unused[i.i].lastUsed, i.lastID) {
		return false
	}

	i.stat.FileCount++
	i.stat.TotalSize += i.r.unused[i.i].size
	i.i++

	return true
}

// Info выдать информацию по текущему неиспользуемому файлу.
// Возвращаемый параметр delay опционален и используется только
// вместе с typ = fileRegistryUnusedFileTypeFixed.
func (i *UnusedIterator) Info() (typ fileRegistryUnusedFileType, id types.Index, delay int32) {
	v := i.r.unused[i.i-1]

	return v.typ, v.id, v.delay
}

// RemoveUnused удаляет дескрипторы неиспользуемых файлов по которым была
// // совершена итерация.
func (r *Registry) RemoveUnused(it *UnusedIterator) {
	r.stats.FileCount -= it.stat.FileCount
	r.stats.TotalSize -= it.stat.TotalSize
	r.unused = r.unused[it.i:]
}
