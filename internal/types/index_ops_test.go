package types_test

import (
	"fmt"
	"testing"

	"github.com/sirkon/mpy6a/internal/types"
)

func ExampleIndex() {
	id := types.NewIndex(1, 2)
	fmt.Println(id)

	id = types.IndexIncIndex(id)
	fmt.Println(id)

	id = types.IndexIncTerm(id)
	fmt.Println(id)

	fmt.Println(types.IndexLess(id, id))
	fmt.Println(types.IndexLess(id, types.IndexIncIndex(id)))
	fmt.Println(types.IndexLess(id, types.IndexIncTerm(id)))

	// Output:
	// 0000000000000001-0000000000000002
	// 0000000000000001-0000000000000003
	// 0000000000000002-0000000000000000
	// false
	// true
	// true
}

func ExampleIndexDecode() {
	id := types.NewIndex(12, 13)

	var buf [16]byte
	types.IndexEncode(buf[:], id)

	fmt.Println(id)
	var cid types.Index
	types.IndexDecode(&cid, buf[:])
	fmt.Println(cid)

	// Output:
	// 000000000000000c-000000000000000d
	// 000000000000000c-000000000000000d
}

func TestIndexOps(t *testing.T) {
	t.Run("small-buffer-encode", func(t *testing.T) {
		defer func() {
			if r := recover(); r != nil {
				t.Logf("got expected panic: %v", r)
			} else {
				t.Error("the test had to raise a panic")
			}
		}()

		var buf [15]byte
		types.IndexEncode(buf[:], types.NewIndex(1, 2))
	})

	t.Run("small-buffer-decode", func(t *testing.T) {
		defer func() {
			if r := recover(); r != nil {
				t.Logf("got expected panic: %v", r)
			} else {
				t.Error("the test had to raise a panic")
			}
		}()

		var buf [15]byte
		types.IndexDecode(new(types.Index), buf[:])
	})
}
