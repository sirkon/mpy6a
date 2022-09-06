package state

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/types"
	"github.com/sirkon/mpy6a/internal/uvarints"
)

// Сущность для вычитки данных сессий из файлов.
type sourceFileReader interface {
	fmt.Stringer

	// SetStart перенос позиции чтения файла на нужную
	SetStart(start uint64) error

	// ReadSession вычитка очередной сессии.
	ReadSession() (repeat uint64, data []byte, err error)

	// Close закрытие процесса вычитки.
	Close() error

	// StartPos физическая позиция вычитки данных.
	StartPos() uint64

	// FinishPos физическая позиция завершения вычитки данных.
	FinishPos() uint64
}

type sourceFileReaderGeneric struct {
	id  types.Index
	src *os.File
	rdr *bufio.Reader

	start  uint64
	finish uint64
}

// SetStart для реализации sourceFileReader.
func (r *sourceFileReaderGeneric) SetStart(start uint64) error {
	if _, err := r.src.Seek(int64(start), 0); err != nil {
		return err
	}

	r.start = start
	return nil
}

// ReadSession для реализации sourceFileReader.
func (r *sourceFileReaderGeneric) ReadSession() (repeat uint64, data []byte, err error) {
	if r.finish > 0 && r.start >= r.finish {
		if r.start == r.finish {
			return 0, nil, io.EOF
		}

		return 0, nil, errorInternalCorruptedSavedSourceFile(
			"rightx bound is tighter than actual data in the file",
		)
	}

	if r.rdr == nil {
		r.rdr = bufio.NewReader(r.src)
	}

	var buf [16]byte
	rptread, err := r.rdr.Read(buf[:8])
	if err != nil {
		return 0, nil, errors.Wrap(err, "Read Session length")
	}

	if rptread < 8 {
		return 0, nil, errorInternalCorruptedSavedSourceFile("incomplete Session repeat time")
	}

	l, err := binary.ReadUvarint(r.rdr)
	if err != nil {
		return 0, nil, errors.Wrap(err, "Read Session data length")
	}

	data = make([]byte, l)
	dataread, err := r.rdr.Read(data)
	if err != nil {
		return 0, nil, errors.Wrap(err, "Read Session data")
	}

	if dataread < int(l) {
		return 0, nil, errorInternalCorruptedSavedSourceFile("incomplete Session data")
	}

	r.start += 8 + uint64(uvarints.LengthInt(l)) + l
	return binary.LittleEndian.Uint64(buf[:8]), data, nil
}

// Close для реализации sourceFileReader.
func (r *sourceFileReaderGeneric) Close() error {
	if err := r.src.Close(); err != nil {
		return err
	}

	return nil
}

// StartPos для реализации sourceFileReader.
func (r *sourceFileReaderGeneric) StartPos() uint64 {
	return r.start
}

// FinishPos для реализации sourceFileReader.
func (r *sourceFileReaderGeneric) FinishPos() uint64 {
	return r.finish
}

type sourceFileReaderSnapshot struct {
	sourceFileReaderGeneric
}

func newSourceSnapshotFileReader(state *State, id types.Index) (_ *sourceFileReaderSnapshot, err error) {
	file, err := os.Open(state.snapshotName(id))
	if err != nil {
		return nil, errors.Wrap(err, "open snapshot file")
	}

	defer func() {
		if err == nil {
			return
		}

		if err := file.Close(); err != nil {
			state.logger.Error(
				errors.Wrap(err, "Close malformed snapshot file").Stg("malformed-snapshot-index", id),
			)
		}
	}()

	var lengthBuf [8]byte
	n, err := file.Read(lengthBuf[:8])
	if err != nil {
		return nil, errors.Wrap(err, "Read snapshot length")
	}
	if n < 8 {
		return nil, errors.New("corrupted saved sessions data length")
	}

	length := binary.LittleEndian.Uint64(lengthBuf[:8])

	res := &sourceFileReaderSnapshot{
		sourceFileReaderGeneric: sourceFileReaderGeneric{
			id:     id,
			src:    file,
			rdr:    bufio.NewReader(file),
			start:  8,
			finish: 8 + length,
		},
	}

	return res, nil
}

func (r *sourceFileReaderSnapshot) String() string {
	var b strings.Builder

	b.WriteString("snapshot-reader[")
	r.id.string(&b)
	b.WriteByte(']')

	return b.String()
}

// sourceFileReaderFlat вычитка из слияний, может использоваться для вычитки
// из хранилища сессий с фиксированным временем задержки повторов, если
// те больше не пишутся.
type sourceFileReaderFlat struct {
	sourceFileReaderGeneric
}

func newSourceFileReaderFlat(state *State, id types.Index) (*sourceFileReaderFlat, error) {
	file, err := os.Open(state.mergedName(id))
	if err != nil {
		return nil, err
	}

	res := &sourceFileReaderFlat{
		sourceFileReaderGeneric: sourceFileReaderGeneric{
			id:     id,
			src:    file,
			rdr:    bufio.NewReader(file),
			start:  0,
			finish: 0,
		},
	}

	return res, nil
}

func (r *sourceFileReaderFlat) String() string {
	var b strings.Builder

	b.WriteString("merged-reader[")
	r.id.string(&b)
	b.WriteByte(']')

	return b.String()
}

var (
	_ sourceFileReader = new(sourceFileReaderSnapshot)
	_ sourceFileReader = new(sourceFileReaderFlat)
)
