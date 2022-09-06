package byteop

// Reuse переиспользование существующего слайса байтов под новую задачу с требуемой длиной.
// Если вместимость источника меньше запрошенной, то он заменяется на новый.
func Reuse(src *[]byte, n int) []byte {
	if cap(*src) < n {
		s := make([]byte, n)
		*src = s

		return s
	}

	return (*src)[:n]
}
