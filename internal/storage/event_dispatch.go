package storage

import (
	"encoding/binary"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/types"
	"github.com/sirkon/mpy6a/internal/uvarints"
)

// LogDispatcher абстракция обработки событий из лога.
// Интерфейс реализуется для процедуры запуска узла и для
// подхвата изменений от лидера на ведомых узлах кластера.
type LogDispatcher interface {
	NewSession(id types.Index) error
	SessionAppend(id, sid types.Index, data []byte) error
	SessionRewrite(id, sid types.Index, data []byte) error
	SessionSave(id, sid types.Index, repeat uint64) error
	SessionClose(id, sid types.Index) error
	SessionRepeat(id types.Index, dsc RepeatSourceProvider) error
	LogRotateStart(id types.Index) error
	SnapshotCreateStart(id types.Index) error
	MergeStart(id types.Index, src []MergeCouple) error
	FixedRotateStart(id types.Index, delay uint32) error
	AsyncCommit(id types.Index) error
	AsyncAbort(id types.Index) error
}

type eventDispatcher struct {
	id   types.Index
	d    LogDispatcher
	data []byte
}

// DispatchEvent функция десериализации данных события и вызова
// соответствующего ему метода ручки LogDispatcher.
func DispatchEvent(id types.Index, d LogDispatcher, data []byte) error {
	if len(data) < 2 {
		return errors.Newf("data is too short to contain event code")
	}

	code := logEventCode(binary.LittleEndian.Uint16(data[:2]))
	e := eventDispatcher{
		id:   id,
		d:    d,
		data: data,
	}
	data = data[2:]

	switch code {
	case logEventNewSession:
		if err := e.dispatchEventNewSession(data); err != nil {
			return errors.Wrap(err, "process new session data")
		}

	case logEventSessionAppend:
		if err := e.dispatchEventSessionAppend(data); err != nil {
			return errors.Wrap(err, "process session append data")
		}

	case logEventSessionRewrite:
		if err := e.dispatchEventSessionRewrite(data); err != nil {
			return errors.Wrap(err, "process session rewrite data")
		}

	case logEventSessionSave:
		if err := e.dispatchEventSessionSave(data); err != nil {
			return errors.Wrap(err, "process session save data")
		}

	case logEventSessionClose:
		if err := e.dispatchEventSessionClose(data); err != nil {
			return errors.Wrap(err, "process session close data")
		}

	case logEventSessionRepeat:
		if err := e.dispatchEventSessionRepeat(data); err != nil {
			return errors.Wrap(err, "process session repeat data")
		}

	case logEventLogRotateStart:
		if err := e.dispatchEventLogRotateStart(data); err != nil {
			return errors.Wrap(err, "process log rotate start data")
		}

	case logEventSnapshotCreateStart:
		if err := e.dispatchEventSnapshotCreateStart(data); err != nil {
			return errors.Wrap(err, "process snapshot rotate start data")
		}

	case logEventMergeStart:
		if err := e.dispatchEventMergeStart(data); err != nil {
			return errors.Wrap(err, "process merge start data")
		}

	case logEventFixedRotateStart:
		if err := e.dispatchEventFixedRotateStart(data); err != nil {
			return errors.Wrap(err, "process fixed rotate start data")
		}

	case logEventAsyncCommit:
		if err := e.dispatchEventAsyncCommit(data); err != nil {
			return errors.Wrap(err, "process async operation commit data")
		}

	case logEventAsyncAbort:
		if err := e.dispatchEventAsyncAbort(data); err != nil {
			return errors.Wrap(err, "process async operation abort data")
		}

	default:
		return errors.Newf("unsupported event code %d", code)
	}

	return nil
}

func (d eventDispatcher) dispatchEventNewSession(data []byte) error {
	if err := d.checkEmpty(data); err != nil {
		return errors.Wrap(err, "check if no data left after the event code")
	}

	if err := d.d.NewSession(d.id); err != nil {
		return errors.Wrap(err, "dispatch event")
	}

	return nil
}

func (d eventDispatcher) dispatchEventSessionAppend(data []byte) error {
	sid, data, err := d.decodeID(data)
	if err != nil {
		return errors.Wrap(err, "decode session id")
	}

	data, err = d.validateAndPassLength(data)
	if err != nil {
		return errors.Wrap(err, "retrieve data length")
	}

	if err := d.d.SessionAppend(d.id, sid, data); err != nil {
		return errors.Wrap(err, "dispatch event")
	}

	return nil
}

func (d eventDispatcher) dispatchEventSessionRewrite(data []byte) error {
	sid, data, err := d.decodeID(data)
	if err != nil {
		return errors.Wrap(err, "decode session id")
	}

	data, err = d.validateAndPassLength(data)
	if err != nil {
		return errors.Wrap(err, "retrieve data length")
	}

	if err := d.d.SessionAppend(d.id, sid, data); err != nil {
		return errors.Wrap(err, "dispatch event")
	}

	return nil
}

func (d eventDispatcher) dispatchEventSessionSave(data []byte) error {
	sid, data, err := d.decodeID(data)
	if err != nil {
		return errors.Wrap(err, "decode session id")
	}

	repeat, rest, err := d.decodeUint64(data)
	if err != nil {
		return errors.Wrap(err, "decode repeat value")
	}

	if err := d.checkEmpty(rest); err != nil {
		return errors.Wrap(err, "check if not data left after repeat bytes")
	}

	if err := d.d.SessionSave(d.id, sid, repeat); err != nil {
		return errors.Wrap(err, "dispatch event")
	}

	return nil
}

func (d eventDispatcher) dispatchEventSessionClose(data []byte) error {
	sid, data, err := d.decodeID(data)
	if err != nil {
		return errors.Wrap(err, "decode session id")
	}

	if err := d.checkEmpty(data); err != nil {
		return errors.Wrap(err, "check if no data left after session id")
	}

	if err := d.d.SessionClose(d.id, sid); err != nil {
		return errors.Wrap(err, "dispatch event")
	}

	return nil
}

func (d eventDispatcher) dispatchEventSessionRepeat(data []byte) error {
	sourceCode, data, err := d.decodeUint16(data)
	if err != nil {
		return errors.Wrap(err, "decode repeat source code")
	}

	switch repeatSourceCode(sourceCode) {
	case RepeatSourceMemoryCode:
		length, rest, err := d.decodeUint64(data)
		if err != nil {
			return errors.Wrap(err, "decode serialized length of in-memory saved session")
		}

		if err := d.checkEmpty(rest); err != nil {
			return errors.Wrap(err, "check if no data left after in memory length")
		}

		if err := d.d.SessionRepeat(d.id, RepeatSourceMemory(length)); err != nil {
			return errors.Wrap(err, "dispatch repeat from memory event")
		}

	case RepeatSourceSnapshotCode:
		sid, l, err := d.dispatchGenericRepeatEvent(data)
		if err != nil {
			return errors.Wrap(err, "decode snapshot repeat source data")
		}

		if err := d.d.SessionRepeat(d.id, RepeatSourceSnapshot{ID: sid, Len: l}); err != nil {
			return errors.Wrap(err, "dispatch repeat from snapshot event")
		}

	case RepeatSourceMergeCode:
		sid, l, err := d.dispatchGenericRepeatEvent(data)
		if err != nil {
			return errors.Wrap(err, "decode merge repeat source data")
		}

		if err := d.d.SessionRepeat(d.id, RepeatSourceMerge{ID: sid, Len: l}); err != nil {
			return errors.Wrap(err, "dispatch repeat from merge event")
		}

	case RepeatSourceFixedCode:
		sid, l, err := d.dispatchGenericRepeatEvent(data)
		if err != nil {
			return errors.Wrap(err, "decode repeat from fixed event")
		}

		if err := d.d.SessionRepeat(d.id, RepeatSourceMerge{ID: sid, Len: l}); err != nil {
			return errors.Wrap(err, "dispatch repeat from fixed event")
		}

	default:
		return errors.New("unsupported repeat source code").Uint16("invalid-repeat-source-code", sourceCode)
	}

	return nil
}

func (d eventDispatcher) dispatchEventLogRotateStart(data []byte) error {
	if err := d.checkEmpty(data); err != nil {
		return errors.Wrap(err, "check if not date left after the event code")
	}

	if err := d.d.LogRotateStart(d.id); err != nil {
		return errors.Wrap(err, "dispatch event")
	}

	return nil
}

func (d eventDispatcher) dispatchEventSnapshotCreateStart(data []byte) error {
	if err := d.checkEmpty(data); err != nil {
		return errors.Wrap(err, "check if not date left after the event code")
	}

	if err := d.d.SnapshotCreateStart(d.id); err != nil {
		return errors.Wrap(err, "dispatch event")
	}

	return nil
}

func (d eventDispatcher) dispatchEventMergeStart(data []byte) (err error) {
	var merges []MergeCouple
	for len(data) > 0 {
		if err := d.checkLengthNotLess(data, 18); err != nil {
			return errors.Wrap(err, "extract merge couple").
				Int("failed-merge-couple-index", len(merges))
		}

		code := binary.LittleEndian.Uint16(data[:2])
		id := types.IndexDecode(data[2:])
		merges = append(merges, MergeCouple{
			Code: repeatSourceCode(code),
			ID:   id,
		})
		data = data[18:]
	}

	if err := d.d.MergeStart(d.id, merges); err != nil {
		return errors.Wrap(err, "dispatch event")
	}

	return nil
}

func (d eventDispatcher) dispatchEventFixedRotateStart(data []byte) error {
	if err := d.checkLength(data, 4); err != nil {
		return errors.Wrap(err, "check if data is correct")
	}

	delay, _, _ := d.decodeUint32(data)

	if err := d.d.FixedRotateStart(d.id, delay); err != nil {
		return errors.Wrap(err, "dispatch event")
	}

	return nil
}

func (d eventDispatcher) dispatchEventAsyncCommit(data []byte) error {
	if err := d.checkEmpty(data); err != nil {
		return errors.Wrap(err, "check if not date left after the event code")
	}

	if err := d.d.AsyncCommit(d.id); err != nil {
		return errors.Wrap(err, "dispatch event")
	}

	return nil
}

func (d eventDispatcher) dispatchEventAsyncAbort(data []byte) error {
	if err := d.checkEmpty(data); err != nil {
		return errors.Wrap(err, "check if not date left after the event code")
	}

	if err := d.d.AsyncAbort(d.id); err != nil {
		return errors.Wrap(err, "dispatch event")
	}

	return nil
}

func (d eventDispatcher) dispatchGenericRepeatEvent(data []byte) (id types.Index, length int, _ error) {
	sid, data, err := d.decodeID(data)
	if err != nil {
		return id, 0, errors.Wrap(err, "decode source id")
	}

	l, rest, err := d.decodeLength(data)
	if err != nil {
		return id, 0, errors.Wrap(err, "decode repeat data length")
	}

	if err := d.checkEmpty(rest); err != nil {
		return id, 0, errors.Wrap(err, "check if no data left after in source length data")
	}

	return sid, int(l), nil
}

func (d eventDispatcher) decodeID(data []byte) (id types.Index, _ []byte, _ error) {
	if len(data) < 16 {
		return id, nil, errors.New("not enough data to extract state index").
			Int("required-length", 16).
			Int("actual-invalid-length", len(data)).
			Int("invalid-data-position", len(d.data)-len(data))
	}

	id = types.IndexDecode(data)
	return id, data[:16], nil
}

func (d eventDispatcher) decodeUint16(data []byte) (uint16, []byte, error) {
	const reqLen = 2
	if len(data) != reqLen {
		return 0, nil, errors.New("not enough data to extract uint16").
			Int("required-length", reqLen).
			Int("actual-invalid-length", len(data)).
			Int("invalid-data-position", len(d.data)-len(data))
	}

	return binary.LittleEndian.Uint16(data[:reqLen]), data[reqLen:], nil
}

func (d eventDispatcher) decodeUint32(data []byte) (uint32, []byte, error) {
	const reqLen = 4
	if len(data) != reqLen {
		return 0, nil, errors.New("not enough data to extract uint32").
			Int("required-length", reqLen).
			Int("actual-invalid-length", len(data)).
			Int("invalid-data-position", len(d.data)-len(data))
	}

	return binary.LittleEndian.Uint32(data[:reqLen]), data[reqLen:], nil
}

func (d eventDispatcher) decodeUint64(data []byte) (uint64, []byte, error) {
	const reqLen = 8
	if len(data) != reqLen {
		return 0, nil, errors.New("not enough data to extract uint64").
			Int("required-length", reqLen).
			Int("actual-invalid-length", len(data)).
			Int("invalid-data-position", len(d.data)-len(data))
	}

	return binary.LittleEndian.Uint64(data[:reqLen]), data[reqLen:], nil
}

func (d eventDispatcher) decodeLength(data []byte) (uint64, []byte, error) {
	length, rest, err := uvarints.Read(data)
	if err != nil {
		return 0, nil, errors.Wrap(err, "extract length").
			Int("invalid-data-position", len(d.data)-len(data))
	}

	return length, rest, nil
}

func (d eventDispatcher) validateAndPassLength(data []byte) (_ []byte, err error) {
	length, rest, err := uvarints.Read(data)
	if err != nil {
		return nil, errors.Wrap(err, "extract data length").
			Int("invalid-data-position", len(d.data)-len(data))
	}

	if int(length) != len(rest) {
		return nil, errors.New("malformed data length").
			Uint64("invalid-length", length).
			Int("rest-length", len(rest)).
			Int("invalid-data-position", len(d.data)-len(data))

	}

	return rest, nil
}

func (d eventDispatcher) checkLength(rest []byte, req int) error {
	if len(rest) != req {
		return errors.New("malformed data").
			Int("unexpected-rest-length", len(rest)).
			Int("required-rest-length", req).
			Int("invalid-data-position", len(d.data)-len(rest))
	}

	return nil
}

func (d eventDispatcher) checkLengthNotLess(rest []byte, req int) error {
	if len(rest) < req {
		return errors.New("less data than required").
			Int("unexpected-rest-length", len(rest)).
			Int("required-rest-length", req).
			Int("invalid-data-position", len(d.data)-len(rest))
	}

	return nil
}

func (d eventDispatcher) checkEmpty(rest []byte) error {
	if len(rest) != 0 {
		return errors.New("unused rest of data").
			Int("unexpected-rest-length", len(rest)).
			Int("invalid-data-position", len(d.data)-len(rest))
	}

	return nil
}
