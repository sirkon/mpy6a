package mpio

import "io"

// TryReadFull почти то же самое что и io.ReadFull с тем отличием, что
// если первое чтение возвращает (0, nil), то сразу происходит выход,
// а последующие чтения возвратившие (0, nil) приводят к ошибке.
func TryReadFull(r io.Reader, buf []byte) (n int, err error) {
	var count int
	for n < len(buf) && err == nil {
		var nn int
		nn, err = r.Read(buf[n:])
		if nn == 0 && err == nil {
			if count == 0 {
				return 0, nil
			}

			return 0, ErrUnexpectedEOD
		}

		n += nn
		count++
	}

	if n == len(buf) {
		err = nil
	} else if n > 0 && err == io.EOF {
		err = io.ErrUnexpectedEOF
	}

	return
}
