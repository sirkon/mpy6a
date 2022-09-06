package msort

import (
	"bufio"
	"encoding/binary"
	"io"
	"math"

	"github.com/sirkon/mpy6a/internal/errors"
)

// MSort сущность для слияния нескольких источников
// сериализованных данных в один.
type MSort struct {
	err error

	srcs    []srcReader
	missing []int

	value struct {
		repeat uint64
		data   []byte
	}
}

// New конструктор итератора слияния
func New(srcs []srcReader) *MSort {
	missing := make([]int, len(srcs))
	for i := range missing {
		missing[i] = i
	}
	return &MSort{
		srcs:    srcs,
		missing: missing,
	}
}

type srcReader struct {
	src    *bufio.Reader
	repeat uint64
}

// Next проверка, что источники ещё не исчерпались
func (s *MSort) Next() bool {
	if s.err != nil {
		return false
	}

	if len(s.srcs) == 0 {
		return false
	}

	for len(s.missing) > 0 {
		i := s.missing[len(s.missing)-1]
		s.missing = s.missing[:len(s.missing)-1]

		src := s.srcs[i].src
		var buf [8]byte
		read, err := src.Read(buf[:8])
		if err != nil {
			if err == io.EOF {
				if read > 0 {
					s.err = errors.New("incomplete session record in the source")
					return false
				}

				s.srcs = append(s.srcs[:i], s.srcs[i+1:]...)
				continue
			}

			s.err = err
			return false
		}

		repeat := binary.LittleEndian.Uint64(buf[:8])
		s.srcs[i].repeat = repeat
	}

	// Ищем ближайшее время среди всех источников
	var tmp = uint64(math.MaxUint64)
	var index int
	for i, src := range s.srcs {
		if src.repeat < tmp {
			index = i
			tmp = src.repeat
		}
	}

	// Читаем запись относящуюся к ближайшему времени
	s.missing = append(s.missing, index)
	src := s.srcs[index]
	length, err := binary.ReadUvarint(src.src)
	if err != nil {
		s.err = errors.Wrap(err, "read session length from the source")
	}
}
