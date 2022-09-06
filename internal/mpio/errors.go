package mpio

import "github.com/sirkon/mpy6a/internal/errors"

type errInternal struct{}

func (errInternal) Error() string {
	return "internal error"
}

func errWriteDataOvergrowsBuffer(piece, bufsize int) error {
	return errors.Newf("write piece size is larger than buffer size").
		Int("large-piece-size", piece).
		Int("buffer-size", bufsize)
}

// EOD "ошибка" сообщающая, что в читалке нет данных, но
// они могут появиться.
var EOD error = noDataYet{}

type noDataYet struct{}

func (noDataYet) Error() string {
	return "there is no data yet"
}

// ErrUnexpectedEOD когда вместо данных при чтении получается пустой результат.
var ErrUnexpectedEOD = errors.Const("empty read when data was expected")
