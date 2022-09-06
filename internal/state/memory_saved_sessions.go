package state

import "github.com/sirkon/mpy6a/internal/storage"

// newMemorySavedSessios конструктор создания пустого контейнера с сохранёнными сессиями.
func newMemorySavedSessios() memorySavedSessions {
	return memorySavedSessions{
		tree: storage.newRBTree(),
	}
}

// memorySavedSessions тип описывающий набор сохранённых сессий упорядоченных по времени повтора
type memorySavedSessions struct {
	tree *storage.rbTree
}

// Clone создание копии контейнера с сессиями.
func (c memorySavedSessions) Clone() *memorySavedSessions {
	return &memorySavedSessions{
		tree: c.tree.Clone(),
	}
}

// Add добавление сессии для повтора в заданное время.
func (c memorySavedSessions) Add(repeat uint64, data sessionData) {
	c.tree.SaveSession(repeat, data)
}

// FirstRepeat выдать самый ранний повтор среди сессий.
// 0 возвращается исключительно в случае когда сохранённых сессий нет.
func (c memorySavedSessions) FirstRepeat() uint64 {
	min, exists := c.tree.Min()
	if !exists {
		return 0
	}

	return min.Repeat
}

// First выдать данные первой сессии. Этот метод не должен зваться, если
// в контейнере нет сессии.
func (c memorySavedSessions) First() (uint64, sessionData) {
	min, _ := c.tree.Min()
	if min == nil {
		return 0, nil
	}

	return min.Repeat, min.Sessions[0]
}

// FirstCommit подтвердить вычитку первой сессии. Этот метод не должен зваться,
// если в контейнере нет сессии.
func (c memorySavedSessions) FirstCommit() {
	min, _ := c.tree.Min()
	min.Sessions = min.Sessions[1:]

	if len(min.Sessions) == 0 {
		c.tree.DeleteSessions(min.Repeat)
	}
}
