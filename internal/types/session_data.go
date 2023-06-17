package types

import (
	"bytes"
	"encoding/binary"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/varsize"
)

// SessionData обёртка для слайсов байт с хранением общей длины
// кодируемых данных для ускорения некоторых задач буферизации.
type SessionData struct {
	buf    [][]byte
	rawlen int
}

// Append добавление нового куска данных в сессию.
func (d *SessionData) Append(data []byte) {
	d.buf = append(d.buf, data)
	d.rawlen += varsize.Len(data) + len(data)
}

// Replace замена данных сессии на кусок.
func (d *SessionData) Replace(data []byte) {
	d.buf = d.buf[:0]
	d.buf = append(d.buf, data)
	d.rawlen = varsize.Len(data) + len(data)
}

// Len возвращает длину текущих данных в кодированном виде.
func (d *SessionData) Len() int {
	return varsize.Len(d.buf) + d.rawlen
}

// Encode метод кодирования данных.
func (d *SessionData) Encode(dst []byte) []byte {
	dst = binary.AppendUvarint(dst, uint64(len(d.buf)))
	for _, b := range d.buf {
		dst = binary.AppendUvarint(dst, uint64(len(b)))
		dst = append(dst, b...)
	}

	return dst
}

// Decode метод декодирования данных.
func (d *SessionData) Decode(src []byte) ([]byte, error) {
	d.buf = d.buf[:0]

	chunks, res := binary.Uvarint(src)
	if res <= 0 {
		if res == 0 {
			return nil, errors.New("decode an amount of data records: record buffer is too small").
				Uint64("length-required", uint64(4)).
				Int("length-actual", len(src))
		}
		return nil, errors.New("decode an amount of data records: malformed uvarint sequence")
	}
	src = src[res:]

	for chunks > 0 {
		chunks--

		dataLen, res := binary.Uvarint(src)
		if res <= 0 {
			if res == 0 {
				return nil, errors.New("decode a length of a single data record: record buffer is too small").
					Uint64("length-required", uint64(4)).
					Int("length-actual", len(src))
			}
			return nil, errors.New("decode a length of a single data record: malformed uvarint sequence")
		}
		src = src[res:]

		if len(src) < int(dataLen) {
			return nil, errors.New("the rest of data is shorter than a claimed single data record length").
				Uint64("data-record-length-claimed", dataLen).
				Int("decoding-buffer-rest-length", len(src))
		}

		d.Append(bytes.Clone(src[:dataLen]))
		src = src[dataLen:]
	}

	return src, nil
}
