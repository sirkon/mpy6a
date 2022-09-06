package state

import (
	"bytes"
	"testing"
)

func TestSavedSessionsContainer(t *testing.T) {
	sessions := []struct {
		repeat uint64
		data   sessionData
	}{
		{
			repeat: 1,
			data:   []byte("1.1"),
		},
		{
			repeat: 2,
			data:   []byte("2"),
		},
		{
			repeat: 1,
			data:   []byte("1.2"),
		},
	}

	c := newMemorySavedSessios()
	for _, session := range sessions {
		c.Add(session.repeat, session.data)
	}

	c = c.Clone()

	checkRepeat := func(index int) bool {
		if v := c.FirstRepeat(); v != sessions[index].repeat {
			t.Errorf(
				"current first repeat must match Session index %d (value %d), got %d",
				index,
				sessions[index].repeat,
				v,
			)
			return false
		}

		return true
	}

	checkSessionData := func(index int) bool {
		repeatAfter, data := c.First()
		if repeatAfter != 1 {
			t.Errorf("current first Session repeat time mush be %d, got %d", 1, repeatAfter)
		}
		if !bytes.Equal(data.Bytes(), sessions[index].data) {
			t.Errorf(
				"current first Session data must match one of Session index %d (value '%s'), got '%s'",
				index,
				string(sessions[index].data),
				data.Bytes(),
			)
			return false
		}

		return true
	}

	// проверка, что первая сессия это 1:1.1
	if !checkRepeat(0) {
		return
	}
	if !checkSessionData(0) {
		return
	}
	c.FirstCommit()

	// проверка, что вторая сессия это 1:1.2
	if !checkRepeat(2) {
		return
	}
	if !checkSessionData(2) {
		return
	}
	c.FirstCommit()

	// проверка, что третья сессия это 2:2
	if !checkRepeat(1) {
		return
	}
	if !checkSessionData(1) {
		return
	}
	c.FirstCommit()

	// проверка, что сессий больше не осталось
	if c.FirstRepeat() != 0 {
		t.Errorf("saved Session container must be exhausted at the moment")
		return
	}
}
