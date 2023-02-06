package storage

import "github.com/sirkon/mpy6a/internal/types"

// RepeatSourceProvider типы реализующие этот интерфейс предоставляют
// информацию об источниках получения сохранённых для повтора сессий.
type RepeatSourceProvider interface {
	isRepeatSourceProvider()
}

type (
	// RepeatSourceMemory сессия из памяти. Предоставляет вычисленное
	// значение длины, которую она бы имела будучи сериализованной.
	RepeatSourceMemory int

	// RepeatSourceSnapshot сессия из слепка.
	RepeatSourceSnapshot struct {
		ID  types.Index
		Len int
	}

	// RepeatSourceMerge сессия из слияния.
	RepeatSourceMerge struct {
		ID  types.Index
		Len int
	}

	// RepeatSourceFixed сессия из ФВП-файла.
	RepeatSourceFixed struct {
		ID  types.Index
		Len int
	}
)

func (RepeatSourceMemory) isRepeatSourceProvider()   {}
func (RepeatSourceSnapshot) isRepeatSourceProvider() {}
func (RepeatSourceMerge) isRepeatSourceProvider()    {}
func (RepeatSourceFixed) isRepeatSourceProvider()    {}
