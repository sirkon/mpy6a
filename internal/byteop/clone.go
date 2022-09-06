package byteop

// Clone копирование данного слайса байтов.
func Clone(data []byte) []byte {
	res := make([]byte, len(data))
	copy(res, data)

	return res
}
