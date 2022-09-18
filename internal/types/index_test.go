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
	// 0000000000000001-0000000000000002
	// 0000000000000001-0000000000000003
	// 0000000000000002-0000000000000000
	// false
	// true
	// true
}
