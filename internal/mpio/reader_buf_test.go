package mpio_test

import (
	"bytes"
	"fmt"
	"io"
	"strings"

	"github.com/sirkon/mpy6a/internal/mpio"
)

func ExampleBufReader() {
	r := mpio.NewBufReader(
		bytes.NewBufferString("123456789"),
		mpio.WithBufferSize[*mpio.BufReader](5),
		mpio.WithReadPosition[*mpio.BufReader](5),
	)

	var buf [4]byte
	var res strings.Builder

	c, err := r.ReadByte()
	if err != nil {
		panic(err)
	}
	res.WriteByte(c)
	fmt.Println(r.PosRead())

	for {
		n, err := r.Read(buf[:])
		if n > 0 {
			res.Write(buf[:n])
		}
		if err != nil {
			if err == io.EOF {
				break
			}

			panic(err)
		}
	}

	fmt.Println(res.String())
	fmt.Println(r.PosRead())

	// Output:
	// 6
	// 123456789
	// 14
}
