package state

import (
	"bytes"
	"testing"

	"github.com/sirkon/deepequal"
	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/tlog"
	"github.com/sirkon/mpy6a/internal/types"
)

func TestDescriptors_EncodeDecode(t *testing.T) {
	d := Descriptors{
		srcs: map[types.Index]*srcDescriptor{
			types.NewIndex(1, 0): {
				id:     types.NewIndex(1, 0),
				curPos: 1,
				len:    100,
			},
			types.NewIndex(2, 1): {
				id:     types.NewIndex(2, 1),
				curPos: 100,
				len:    1000,
			},
		},
		log: &logDescriptor{
			id:      types.NewIndex(100, 200),
			firstID: types.NewIndex(100, 300),
			lastID:  types.NewIndex(500, 1000),
			len:     100500,
		},
		usedSrcs: []usedSrc{
			{
				id:  types.NewIndex(1, 0),
				len: 100,
			},
			{
				id:  types.NewIndex(1, 5),
				len: 200,
			},
		},
		usedLogs: []*logDescriptor{
			{
				id:      types.NewIndex(50, 100),
				firstID: types.NewIndex(50, 105),
				lastID:  types.NewIndex(75, 19),
				len:     300,
			},
		},
	}

	var buf bytes.Buffer
	if err := d.Encode(&buf); err != nil {
		tlog.Error(t, errors.Wrap(err, "encode descriptors"))
		return
	}

	var e Descriptors
	if err := e.Decode(&buf); err != nil {
		tlog.Error(t, errors.Wrap(err, "decode encoded descriptors data"))
		return
	}

	deepequal.SideBySide(t, "descriptors", &d, &e)
}
