package types_test

import (
	"fmt"

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
	// 00000001-00000002
	// 00000001-00000003
	// 00000002-00000000
	// false
	// true
	// true
}
