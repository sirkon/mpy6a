package state

// NewSavedSessios конструктор создания пустого контейнера с сохранёнными сессиями.
func NewSavedSessios() SavedSessions {
	return SavedSessions{
		tree: newRBTree(),
	}
}

// SavedSessions тип описывающий набор сохранённых сессий упорядоченных по времени повтора
type SavedSessions struct {
	tree *rbTree
}

// Clone создание копии контейнера с сессиями.
func (c SavedSessions) Clone() SavedSessions {
	return SavedSessions{
		tree: c.tree.Clone(),
	}
}

// Add добавление сессии для повтора в заданное время.
func (c SavedSessions) Add(repeat uint64, data SessionData) {
	c.tree.SaveSession(repeat, data)
}

// FirstRepeat выдать самый ранний повтор среди сессий.
// 0 возвращается исключительно в случае когда сохранённых сессий нет.
func (c SavedSessions) FirstRepeat() uint64 {
	min, exists := c.tree.Min()
	if !exists {
		return 0
	}

	return min.Repeat
}

// First выдать данные первой сессии. Этот метод не должен зваться, если
// в контейнере нет сессии.
func (c SavedSessions) First() SessionData {
	min, _ := c.tree.Min()
	return min.Sessions[0]
}

// FirstCommit подтвердить вычитку первой сессии. Этот метод не должен зваться,
// если в контейнере нет сессии.
func (c SavedSessions) FirstCommit() {
	min, _ := c.tree.Min()
	min.Sessions = min.Sessions[1:]

	if len(min.Sessions) == 0 {
		c.tree.DeleteSessions(min.Repeat)
	}
}
