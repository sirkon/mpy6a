package fileregistry

import "fmt"

func ExampleUnusedFileTypeName() {
	fmt.Println(fileRegistryUnusedFileTypeLog)
	fmt.Println(fileRegistryUnusedFileTypeSnapshot)
	fmt.Println(fileRegistryUnusedFileTypeMerge)
	fmt.Println(fileRegistryUnusedFileTypeFixed)
	fmt.Println(fileRegistryUnusedFileTypeTmp)
	fmt.Println(fileRegistryUnusedFileType(-1))

	// Output:
	// log
	// snapshot
	// merge
	// fixed
	// temporary
	// unknown file type -1
}
