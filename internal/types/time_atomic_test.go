package types_test

import (
	"fmt"
	"time"

	"github.com/sirkon/mpy6a/internal/types"
)

func ExampleNewTimeAtomic() {
	a := types.NewTimeAtomic()
	now := time.Now()
	a.Set(now)
	time.Sleep(time.Second / 100)
	nn := a.Get()
	fmt.Println(nn.Equal(now))
	// Output:
	// true
}
