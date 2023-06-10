package types

import (
	"reflect"
	"time"
	"unsafe"
)

// TimeAtomic примитив для атомарного использования в рамках
// одной временной зоны.
//
// Warning может сломаться в версиях Go старше 1.20 – как только
//  внутреннее представление перестанет быть эквивалентным
//  (uint64, int64, *time.Location) с точки зрения раскладки в памяти.
type TimeAtomic struct {
	data []byte
	zone *time.Location
}

// NewTimeAtomic создаёт объект для атомарного времени.
func NewTimeAtomic() TimeAtomic {
	n := time.Now()

	res := TimeAtomic{
		data: newBufferAtomic128(),
		zone: n.Location(),
	}
	res.Set(n)
	return res
}

// Set атомарно устанавливает значение времени в данное.
func (a *TimeAtomic) Set(t time.Time) {
	ti := (*timeImposter)(unsafe.Pointer(&t))
	setAtomic(uintptr(unsafe.Pointer(&a.data[0])), ti.v1, ti.v2)
}

// Get атомарно получает время.
func (a *TimeAtomic) Get() (res time.Time) {
	v1, v2 := getAtomic(uintptr(unsafe.Pointer(&a.data[0])))
	t := timeImposter{
		v1:  v1,
		v2:  v2,
		loc: a.zone,
	}

	return t.asTime()
}

type timeImposter struct {
	v1  uint64
	v2  uint64
	loc *time.Location
}

func (ti *timeImposter) asTime() time.Time {
	return *(*time.Time)(unsafe.Pointer(ti))
}

func init() {
	// проверка, что внутреннее содержимое типа не изменилось
	var data [1]struct{}
	data[reflect.ValueOf(time.Time{}).Type().Size()-24] = struct{}{}
}
