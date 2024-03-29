package logio

import (
	"bufio"
	"encoding/binary"
	"io"
	"os"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/mpio"
	"github.com/sirkon/mpy6a/internal/types"
	"github.com/sirkon/mpy6a/internal/uvarints"
)

// NewReader создаёт итератор для чтения записанных в файл событий из лога.
func NewReader(name string, opts ...ReaderOption) (_ *ReadIterator, err error) {
	file, err := os.Open(name)
	if err != nil {
		return nil, errors.Wrap(err, "open log file")
	}

	defer func() {
		if err == nil {
			return
		}

		if cErr := file.Close(); cErr != nil {
			panic(errors.Wrap(err, "close file after processing failure"))
		}
	}()

	buf := bufio.NewReader(file)

	frame, evlim, err := readMetadata(buf)
	if err != nil {
		return nil, errors.Wrap(err, "load file metadata")
	}

	res := &ReadIterator{
		src: &fileBuf{
			buf: buf,
			src: file,
		},
		frame: int(frame),
		evlim: int(evlim),
		pos:   fileMetaInfoHeaderSize,
	}
	if err := res.applyOptions(opts...); err != nil {
		return nil, errors.Wrap(err, "apply options")
	}

	return res, nil
}

// NewReaderInProcess вычитка файла с логом всё ещё используемого
// системой.
func NewReaderInProcess(w *Writer, opts ...ReaderOption) (*ReadIterator, error) {
	r, err := mpio.NewSimReader(w.dst, mpio.SimReaderOptions())
	if err != nil {
		return nil, errors.Wrap(err, "create log file reader")
	}

	frame, evlim, err := readMetadata(r)
	if err != nil {
		return nil, errors.Wrap(err, "read log file metadata")
	}

	res := &ReadIterator{
		src:   r,
		frame: int(frame),
		evlim: int(evlim),
		pos:   fileMetaInfoHeaderSize,
	}
	if err := res.applyOptions(opts...); err != nil {
		return nil, errors.Wrap(err, "apply options")
	}

	return res, nil
}

// logReader абстракция позволяющая единообразно работать с
// источниками вычитки лога, как с простыми файлами, так и
// с экземплярами SimReader
type logReader interface {
	io.Reader
	io.ByteReader
	io.Closer
	io.Seeker
}

// ReadIterator итератор по файлу с данными лога.
type ReadIterator struct {
	src   logReader
	frame int
	evlim int
	pos   uint64

	id     types.Index
	before types.Index
	data   []byte
	delta  int
	err    error
}

// Next вычитка следующего события.
func (it *ReadIterator) Next() bool {
	if it.err != nil {
		return false
	}
	it.delta = 0

	var passed bool
	if it.frameRest() < 18 {
		passed = true
		it.delta = it.frameRest()
		if err := it.passBytes(it.frameRest()); err != nil {
			it.err = errors.Wrap(err, "pass frame rest which is too small to hold an event")
			return false
		}
	}

	var buf [16]byte
	if n, err := mpio.TryReadFull(it.src, buf[:]); err != nil {
		it.err = errors.Wrap(err, "read event index").Int("unexpected-data-length", n)
		return false
	}
	types.IndexDecode(&it.id, buf[:])
	if it.id.Term == 0 {
		if passed {
			it.err = errors.New("got zero term just after a short frame rest pass").
				Uint64("read-start-position", it.pos).
				Int("read-position-shift", it.delta)
			return false
		}
		it.delta += it.frameRest()
		if err := it.passBytes(it.frameRest() - 16); err != nil {
			it.err = errors.Wrap(err, "pass frame rest where event with zero term was detected")
			return false
		}

		if n, err := mpio.TryReadFull(it.src, buf[:]); err != nil {
			it.err = errors.Wrap(err, "read event index after a frame rest pass")
			return false
		} else if n < 16 {
			it.err = errors.New("missing event index")
			return false
		}

		types.IndexDecode(&it.id, buf[:])
		if it.id.Term == 0 {
			it.err = errors.New("got zero term just after frame rest pass")
			return false
		}
	}

	if it.before.Term != 0 && !types.IndexLess(it.id, it.before) {
		it.err = io.EOF
		return false
	}

	uvarint, err := binary.ReadUvarint(it.src)
	if err != nil {
		it.err = errors.Wrap(err, "read event data length")
		return false
	}
	l := int(uvarint)
	if cap(it.data) < l {
		it.data = make([]byte, l)
	}
	it.data = it.data[:l]
	if n, err := mpio.TryReadFull(it.src, it.data); err != nil {
		it.err = errors.Wrap(err, "read event data")
		return false
	} else if n < l {
		it.err = errors.New("missing event data").Int("expected-length", l).Int("actual-length", n)
	}

	it.delta += 16 + uvarints.LengthInt(l) + l
	it.pos += uint64(it.delta)
	return true
}

// Event получить событие. Кроме данных события возвращается так же
// длина данных из файла, которые пришлось вычитать.
func (it *ReadIterator) Event() (id types.Index, data []byte, size int) {
	return it.id, it.data, it.delta
}

func (it *ReadIterator) Err() error {
	if it.err == nil {
		return nil
	}

	if errors.Is(it.err, io.EOF) {
		return nil
	}

	return it.err
}

// Close закрытие источника итерирования.
func (it *ReadIterator) Close() error {
	return it.src.Close()
}

func (it *ReadIterator) applyOptions(opts ...ReaderOption) error {
	for _, opt := range opts {
		if err := opt.apply(it, it.src); err != nil {
			return errors.Wrap(err, opt.String())
		}
	}

	return nil
}

func (it *ReadIterator) passBytes(l int) error {
	if len(it.data) < l {
		it.data = make([]byte, l)
	}

	n, err := mpio.TryReadFull(it.src, it.data[:l])
	if err != nil {
		return err
	}

	if n == 0 {
		return io.EOF
	}

	return nil
}

func (it *ReadIterator) frameRest() int {
	v := it.frame - int((it.pos-16)%uint64(it.frame))
	return v
}

func readMetadata(buf io.Reader) (frame uint64, evlim uint64, err error) {
	var tmp [16]byte
	if _, err := mpio.TryReadFull(buf, tmp[:]); err != nil {
		return 0, 0, errors.Wrap(err, "read metadata")
	}

	frame = binary.LittleEndian.Uint64(tmp[:8])
	evlim = binary.LittleEndian.Uint64(tmp[8:])

	if frame > frameSizeHardLimit {
		return 0, 0, errors.New("invalid frame size").
			Uint64("invalid-frame-size", frame)
	}
	if frame < evlim {
		return 0, 0, errors.New("frame cannot be smaller than an event evlim").
			Uint64("frame-size", frame).
			Uint64("event-evlim-size", evlim)
	}
	if evlim < 18 {
		return 0, 0, errors.New("event evlim is too small").
			Uint64("invalid-evlim", evlim).
			Int("least-event-evlim", 18)
	}

	return frame, evlim, nil
}
