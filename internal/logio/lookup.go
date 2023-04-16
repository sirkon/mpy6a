package logio

import (
	"encoding/binary"
	"io"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/types"
	"github.com/sirkon/mpy6a/internal/uvarints"
	"golang.org/x/exp/mmap"
)

// LookupNext поиск отступа следующего за данным события.
// Событие НЕ ДОЛЖНО быть первым или последним в логе.
// Файл ОБЯЗАТЕЛЬНО должен содержать записи событий относящихся
// как к более раннему, так и к более позднему периоду.
func LookupNext(name string, id types.Index, logger func(error)) (_ LookupResult, err error) {
	file, err := mmap.Open(name)
	if err != nil {
		return nil, errors.Wrap(err, "open file")
	}
	defer func() {
		if cErr := file.Close(); cErr != nil {
			if err == nil {
				err = cErr
				return
			}

			logger(errors.Wrap(cErr, "close file"))
		}
	}()

	if file.Len() == fileMetaInfoHeaderSize {
		return nil, errors.Wrap(ErrorLogIntegrityCompromised{}, "no events in the file")
	}

	frame, evlim, err := readMmapedFileHeader(file)
	if err != nil {
		return nil, errors.Wrap(err, "read file metadata")
	}

	l := uint64(file.Len())
	var left uint64
	rightFrame := (l - fileMetaInfoHeaderSize) / frame
	if (l-fileMetaInfoHeaderSize)%frame != 0 {
		// rightFrame это индекс СЛЕДУЮЩЕГО ЗА ПОСЛЕДНИМ кадра,
		// т.е. не индекс реального кадра.
		rightFrame++
	}

	var higherFrameID types.Index
	for rightFrame-left > 1 {
		c := (rightFrame - left) / 2
		pos := c*frame + fileMetaInfoHeaderSize

		var buf [16]byte
		_, err := file.ReadAt(buf[:16], int64(pos))
		if err != nil {
			// Здесь не может быть io.EOF по-определению.
			return nil, errors.Wrap(err, "read first event index").
				Uint64("frame-no", c).
				Uint64("frame-offset", pos).
				Uint64("frame-length", frame)
		}

		cid := types.IndexDecode(buf[:16])
		switch types.IndexCmp(cid, id) {
		case -1:
			left = c
			continue
		case 0:
			// Искомое событие располагается прямо в начале кадра, нужно пропустить его.
			// Читаем такое количество в байт, в которых гарантированно поместится как
			// само событие, так и идентификатор следующего.
			buf := make([]byte, uvarints.LengthInt(evlim)+int(evlim)+16)
			n, err := file.ReadAt(buf, int64(pos)+16)
			if err != nil {
				if err != io.EOF || n <= 0 {
					return nil, errors.Wrap(err, "read frame first event data + second event id").
						Uint64("frame-no", c).
						Uint64("frame-offset", pos).
						Uint64("frame-length", frame).
						Stg("first-frame-id", cid)
				}
			}

			eventLen, rest, err := uvarints.Read(buf)
			if err != nil {
				return nil, errors.Wrap(err, "read first event data length").
					Uint64("frame-no", c).
					Uint64("frame-offset", pos).
					Uint64("frame-length", frame).
					Stg("first-frame-id", cid)
			}

			rest = rest[eventLen:]
			if types.IndexDecode(rest).Term == 0 {
				// Первое событие является последним в кадре, возвращаем начало следующего кадра.
				// Следующий кадр обязательно существует, т.к. событие не является последним.
				return LookupResultFound((c+1)*frame + fileMetaInfoHeaderSize), nil
			}

			return LookupResultFound(pos + 16 + uint64(uvarints.LengthInt(eventLen)) + eventLen), nil
		case 1:
			rightFrame = c
			higherFrameID = cid
			continue
		}
	}

	// Нужный кадр найден, его позиция это left, ищем в нём.
	buf := make([]byte, frame)
	pos := left*frame + fileMetaInfoHeaderSize
	n, err := file.ReadAt(buf, int64(pos))
	if err != nil {
		if err != io.EOF || n <= 0 {
			return nil, errors.New("read frame data").
				Uint64("frame-no", left).
				Uint64("frame-offset", pos).
				Uint64("frame-length", frame)
		}
	}
	buf = buf[:n]

	var prevID types.Index
	var prevPos uint64
	for {
		cid := types.IndexDecodeSafe(buf)
		if cid.Term == 0 {
			// Дошли до конца кадра, но элемент так и не найден.
			// Это означает, что нужной записи нет.
			// higherFrameID в этом случае обязательно будет инициализирован, т.к. иначе
			// файл бы не имел событий позднее данного.
			return &LookupResultIsMissing{
				LastBeforeID:     prevID,
				LastBeforeOffset: prevPos,
				NextID:           higherFrameID,
				NextOffset:       (left+1)*frame + fileMetaInfoHeaderSize,
			}, nil
		}

		switch types.IndexCmp(cid, id) {
		case -1:
			// Событие предшествует искомому, переходим к вычитке данных следующего.
			eventLen, _, err := uvarints.Read(buf)
			if err != nil {
				return nil, errors.Wrap(err, "read event data length").
					Uint64("frame-no", left).
					Uint64("event-offset", pos).
					Stg("event-id", cid)
			}

			prevPos = pos
			prevID = cid
			delta := 16 + uvarints.LengthInt(eventLen) + int(eventLen)
			buf = buf[delta:]
			pos += uint64(delta)
			continue
		case 0:
			// Событие найдено, нужно определить позицию следующего.
			eventLen, _, err := uvarints.Read(buf)
			if err != nil {
				return nil, errors.Wrap(err, "read the event data length").
					Uint64("frame-no", left).
					Uint64("event-offset", pos)
			}

			delta := 16 + uvarints.LengthInt(eventLen) + int(eventLen)
			buf = buf[delta:]
			cid := types.IndexDecodeSafe(buf)
			if cid.Term == 0 {
				// Т.е. мы дошли до последнего события в кадре. Следующее событие лежит
				// в следующем кадре.
				return LookupResultFound((left+1)*frame + fileMetaInfoHeaderSize), nil
			}

			// Следующее событие успешно прочитано в текущем кадре, возвращаем успех.
			return LookupResultFound(pos + uint64(delta)), nil

		case 1:
			// Ровно перед этим было событие "меньше", т.е.
			// искомого события не имеется. Пропускаем.
			return &LookupResultIsMissing{
				LastBeforeID:     prevID,
				LastBeforeOffset: prevPos,
				NextID:           cid,
				NextOffset:       pos,
			}, nil
		}
	}
}

func readMmapedFileHeader(file *mmap.ReaderAt) (frame uint64, limit uint64, err error) {
	var buf [fileMetaInfoHeaderSize]byte
	read, err := file.ReadAt(buf[:], 0)
	if err != nil {
		return 0, 0, errors.Wrap(err, "read file meta info")
	}
	if read < fileMetaInfoHeaderSize {
		return 0, 0, errors.Newf("corrupted file meta info header").
			Int("required-header-length", fileMetaInfoHeaderSize).
			Int("corrupted-length", read)
	}

	frame = binary.LittleEndian.Uint64(buf[:8])
	limit = binary.LittleEndian.Uint64(buf[8:])

	if frame > frameSizeHardLimit {
		return 0, 0, errors.New("invalid frame size").
			Uint64("invalid-frame-size", frame)
	}
	if frame < limit {
		return 0, 0, errors.New("frame cannot be smaller than a evlim").
			Uint64("frame-size", frame).
			Uint64("evlim-size", limit)
	}
	if limit < 18 {
		return 0, 0, errors.New("event data evlim is too small").
			Uint64("invalid-evlim", limit).
			Int("least-evlim", 18)
	}

	return frame, limit, nil
}

// LookupResult defines constraints for lookup result.
type LookupResult interface {
	isLookupResult()
}

// LookupResultFound returned for the exact match.
// The returned uint64 value points to the offset of the
// next event data after the requested one. Will be
// negative if the requested event is the last in the file.
type LookupResultFound uint64

// Uint64 offset value.
func (v LookupResultFound) Uint64() uint64 {
	return uint64(v)
}

func (LookupResultFound) isLookupResult() {}

// LookupResultIsMissing returned when no element was
// found yet there are elements having lower id than
// requested.
type LookupResultIsMissing struct {
	// LastBeforeID the index of the furthest event before the requested.
	LastBeforeID     types.Index
	LastBeforeOffset uint64

	// NextID the index of the first event after the "last before".
	NextID     types.Index
	NextOffset uint64
}

func (*LookupResultIsMissing) isLookupResult() {}

var (
	_ LookupResult = LookupResultFound(0)
	_ LookupResult = &LookupResultIsMissing{}
)
