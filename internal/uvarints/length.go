package uvarints

import (
	"math/bits"

	"golang.org/x/exp/constraints"
)

// Length возвращает длину в uvarint для длинны данного слайса.
func Length(v []byte) int {
	return (bits.Len64(uint64(len(v))) + 6) / 7
}

// LengthInt возвращает длину в uvarint для данного целого числа.
func LengthInt[T constraints.Integer](v T) int {
	return (bits.Len64(uint64(v)) + 6) / 7
}
