package state_test

import (
	"bytes"
	"testing"

	"github.com/sirkon/mpy6a/internal/state"
)

func TestSavedSessionsContainer(t *testing.T) {
	sessions := []struct {
		repeat uint64
		data   state.SessionData
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

	c := state.NewSavedSessios()
	for _, session := range sessions {
		c.Add(session.repeat, session.data)
	}

	c = c.Clone()

	checkRepeat := func(index int) bool {
		if v := c.FirstRepeat(); v != sessions[index].repeat {
			t.Errorf(
				"current first repeat must match session index %d (value %d), got %d",
				index,
				sessions[index].repeat,
				v,
			)
			return false
		}

		return true
	}

	checkSessionData := func(index int) bool {
		if !bytes.Equal(c.First().Bytes(), sessions[index].data) {
			t.Errorf(
				"current first session data must match one of session index %d (value '%s'), got '%s'",
				index,
				string(sessions[index].data),
				string(c.First().Bytes()),
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
		t.Errorf("saved session container must be exhausted at the moment")
		return
	}
}
