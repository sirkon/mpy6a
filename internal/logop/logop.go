package logop

import "github.com/sirkon/mpy6a/internal/types"

// Logop абстракция представляющая записи в логе,
// где каждой записи соответствует вызов одного метода.
type Logop interface {
	New(theme uint32) error
	Record(sid types.Index, data []byte) error
	Restore(n uint32) error
	Delete(sid types.Index) error
	Store(sid types.Index, repeat OptionalRepeat) error
}

// OptionalRepeat тип для продолжительности задержки
// перед повтором. Нулевое значение указывает на
// отсутствие параметра.
type OptionalRepeat = uint32
