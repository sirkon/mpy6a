package sourceio

import (
	"encoding/binary"
	"io"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/types"
	"github.com/sirkon/mpy6a/internal/uvarints"
	"github.com/sirkon/varsize"
)

// NewIteratorSize конструктор итератора с данным размером буфера.
// Величине size желательно быть достаточно большой, чтобы вмещать
// нормальное число сессий.
func NewIteratorSize(src io.Reader, size int) *Iterator {
	return &Iterator{
		src:  src,
		buf:  make([]byte, size),
		size: size,
	}
}

// Iterator итератор по источнику.
type Iterator struct {
	src  io.Reader
	buf  []byte
	rest []byte
	size int

	record struct {
		len     uint64
		repeat  uint64
		session types.Session
	}
	err error
}

// Next вычитка следующей сохранённой сессии из источника.
func (it *Iterator) Next() bool {
	if it.err != nil {
		return false
	}

	if len(it.rest) == 0 && cap(it.buf) > 0 {
		n, err := it.src.Read(it.buf)
		if err != nil {
			if err != io.EOF || n == 0 {
				it.err = err
				return false
			}
		}
		it.rest = it.buf[:n]
	}

	if err := it.readRepeat(); err != nil {
		it.err = errors.Wrap(err, "read repeat time")
		return false
	}

	if err := it.readData(); err != nil {
		it.err = errors.Wrap(err, "read saved session session")
		return false
	}

	return true
}

// RepeatData отдать данные для повтора. Здесь:
//  - passed это число байт в которых хранилась закодированная информация повтора сессии.
//  - repeat – время повтора сессии.
//  - session - собственно данные сессии.
func (it *Iterator) RepeatData() (passed uint64, repeat uint64, session types.Session) {
	return it.record.len, it.record.repeat, it.record.session
}

// Err возвращает ошибку времени итерации.
func (it *Iterator) Err() error {
	if errors.Is(it.err, io.EOF) {
		return nil
	}

	return it.err
}

func (it *Iterator) readRepeat() error {
	if err := it.required(8); err != nil {
		return errors.Wrap(err, "claim a place for u64")
	}

	it.record.repeat = binary.LittleEndian.Uint64(it.rest)
	it.rest = it.rest[8:]
	return nil
}

func (it *Iterator) readData() error {
	if err := it.required(binary.MaxVarintLen64); err != nil {
		return errors.Wrap(err, "claim a place for session length")
	}

	length, rest, err := uvarints.Read(it.rest)
	if err != nil {
		return errors.Wrap(err, "take session length")
	}

	it.record.len = 8 + uint64(varsize.Uint(length)) + length
	it.rest = rest

	if err := it.required(int(length)); err != nil {
		return errors.Wrap(err, "claim a place for session")
	}

	if uint64(len(it.rest)) < length {
		return errors.New("not enough session left in the source").
			Pfx("session-length").
			Uint64("required", length).
			Int("actual", len(it.rest))
	}

	if err := types.SessionDecode(&it.record.session, it.rest[:length]); err != nil {
		return errors.Wrap(err, "decode session session")
	}

	it.rest = it.rest[length:]
	return nil
}

// Ошибка отсюда не требует аннотации.
func (it *Iterator) required(n int) error {
	l := len(it.rest)
	if l >= n {
		return nil
	}
	if cap(it.buf) < n {
		it.buf = make([]byte, n)
	}

	copy(it.buf, it.rest)
	k, err := it.src.Read(it.buf[l:])
	if err != nil && k == 0 {
		return errors.Wrap(err, "need more session").
			Pfx("session-length").
			Int("required", n).
			Int("left", l)
	}

	it.rest = it.buf[:l+k]
	return nil
}
