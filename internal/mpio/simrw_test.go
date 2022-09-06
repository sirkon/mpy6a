package mpio_test

import (
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/mpio"
)

func ExampleSimRW() {
	const name = "testdata/file"
	const initFileContent = "1234\n56789\nabc"

	if err := os.MkdirAll("testdata", 0755); err != nil {
		panic(errors.Wrap(err, "create directory for testing data"))
	}

	if err := os.WriteFile(name, []byte(initFileContent), 0644); err != nil {
		panic(errors.Wrap(err, "write initial file"))
	}

	s, err := mpio.NewSimRW(
		name,
		mpio.WithBufferSize[*mpio.SimRW](1024),
		mpio.WithErrorLogger[*mpio.SimRW](func(err error) {
			fmt.Println(err)
		}),
		mpio.WithReadPosition[*mpio.SimRW](5),
		mpio.WithWritePosition[*mpio.SimRW](11),
	)
	if err != nil {
		panic(errors.Wrap(err, "setup simrw"))
	}

	waitChan := make(chan struct{})
	go func() {
		<-waitChan

		if _, err := s.Write([]byte("xyz")); err != nil {
			panic(errors.Wrap(err, "write to the file"))
		}

		if err := s.CloseWrite(); err != nil {
			panic(errors.Wrap(err, "close write"))
		}
	}()

	var res strings.Builder
	var buf [4]byte

	// Вначале читаем до конца, а затем разрешаем писать.
	for {
		n, err := s.Read(buf[:])
		if err != nil {
			panic(errors.Wrap(err, "read file data"))
		}

		if n == 0 {
			close(waitChan)
			break
		}

		res.Write(buf[:n])
	}

	// Сейчас читаем до конца
	if _, err := io.Copy(&res, s); err != nil {
		panic(errors.Wrap(err, "read the rest"))
	}

	fmt.Println(res.String())

	// Output:
	// 56789
	// xyz
}
