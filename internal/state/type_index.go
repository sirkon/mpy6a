package state

import (
	"bufio"
	"encoding/binary"
	"io"

	"github.com/sirkon/errors"
)

// Index счётчик состояния.
type Index struct {
	Term  uint64
	Index uint64
}

// IncTerm увеличить номер срока на 1. Параллельно сбрасывает индекс с рамках срока.
func (i *Index) IncTerm() {
	i.Term++
	i.Index = 0
}

// IncIndex увеличить индекс в рамках срока на 1.
func (i *Index) IncIndex() {
	i.Index++
}

// Encode сериализация индекса в заданный приёмник.
func (i Index) Encode(dst io.Writer) error {
	var buf [16]byte

	binary.LittleEndian.PutUint64(buf[:8], i.Term)
	binary.LittleEndian.PutUint64(buf[8:16], i.Index)

	if _, err := dst.Write(buf[:16]); err != nil {
		return err
	}

	return nil
}

// Decode восстановление индекса из заданного источника.
func (i *Index) Decode(src *bufio.Reader) error {
	var buf [16]byte

	read, err := src.Read(buf[:16])
	if err != nil {
		return errors.Wrap(err, "read state index data from source")
	}

	if read < 16 {
		return errors.Newf("corrupted index data in the source: 16 bytes required, got %d", read)
	}

	i.Term = binary.LittleEndian.Uint64(buf[:8])
	i.Index = binary.LittleEndian.Uint64(buf[8:16])

	return nil
}
