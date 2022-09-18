package storage

import (
	"bytes"
	"io"
	"reflect"
	"testing"

	"github.com/golang/mock/gomock"
	"github.com/sirkon/mpy6a/internal/byteop"
	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/mpio"
	"github.com/sirkon/mpy6a/internal/storage/internal/mocks"
	"github.com/sirkon/mpy6a/internal/testlog"
	"github.com/sirkon/mpy6a/internal/types"
)

func TestSessionEncoding(t *testing.T) {
	session := types.NewSession(types.NewIndex(1, 2), 3, []byte("123"))

	tests := []struct {
		name    string
		sess    types.Session
		repeat  uint64
		modify  func(t *testing.T, b []byte) SessionReader
		wantErr bool
		err     error
	}{
		{
			name:    "ok",
			sess:    session,
			repeat:  15,
			modify:  nil,
			wantErr: false,
		},
		{
			name:   "invalid encoded data",
			sess:   session,
			repeat: 15,
			modify: func(_ *testing.T, b []byte) SessionReader {
				return bytes.NewReader(b[:15])
			},
			wantErr: true,
		},
		{
			name:   "end of reader",
			sess:   session,
			repeat: 15,
			modify: func(_ *testing.T, b []byte) SessionReader {
				return bytes.NewReader(nil)
			},
			wantErr: true,
			err:     io.EOF,
		},
		{
			name:   "no data",
			sess:   session,
			repeat: 15,
			modify: func(t *testing.T, b []byte) SessionReader {
				ctrl := gomock.NewController(t)
				m := mocks.NewSessionReaderMock(ctrl)
				m.EXPECT().Read(gomock.Len(8)).Return(0, nil)

				return m
			},
			wantErr: true,
			err:     mpio.EOD,
		},
		{
			name:   "error on repeat read",
			sess:   session,
			repeat: 15,
			modify: func(t *testing.T, b []byte) SessionReader {
				ctrl := gomock.NewController(t)
				m := mocks.NewSessionReaderMock(ctrl)
				m.EXPECT().Read(gomock.Any()).Return(0, errors.New("failed to read"))
				return m
			},
			wantErr: true,
			err:     nil,
		},
		{
			name:   "EOF on read length",
			sess:   session,
			repeat: 15,
			modify: func(t *testing.T, b []byte) SessionReader {
				ctrl := gomock.NewController(t)
				m := mocks.NewSessionReaderMock(ctrl)
				gomock.InOrder(
					m.EXPECT().Read(gomock.Len(8)).DoAndReturn(func(buf []byte) (n int, err error) {
						copy(buf, b[:8])
						return 8, nil
					}),
					m.EXPECT().ReadByte().DoAndReturn(func() (byte, error) {
						return 0, io.EOF
					}),
				)

				return m
			},
			wantErr: true,
			err:     io.ErrUnexpectedEOF,
		},
		{
			name:   "EOD on read length",
			sess:   session,
			repeat: 15,
			modify: func(t *testing.T, b []byte) SessionReader {
				ctrl := gomock.NewController(t)
				m := mocks.NewSessionReaderMock(ctrl)
				gomock.InOrder(
					m.EXPECT().Read(gomock.Len(8)).DoAndReturn(func(buf []byte) (n int, err error) {
						copy(buf, b[:8])
						return 8, nil
					}),
					m.EXPECT().ReadByte().DoAndReturn(func() (byte, error) {
						return 0, mpio.EOD
					}),
				)

				return m
			},
			wantErr: true,
			err:     mpio.ErrUnexpectedEOD,
		},
		{
			name:   "other read length error",
			sess:   session,
			repeat: 15,
			modify: func(t *testing.T, b []byte) SessionReader {
				ctrl := gomock.NewController(t)
				m := mocks.NewSessionReaderMock(ctrl)
				gomock.InOrder(
					m.EXPECT().Read(gomock.Len(8)).DoAndReturn(func(buf []byte) (n int, err error) {
						copy(buf, b[:8])
						return 8, nil
					}),
					m.EXPECT().ReadByte().DoAndReturn(func() (byte, error) {
						return 0, errors.New("read length byte error")
					}),
				)

				return m
			},
			wantErr: true,
		},
		{
			name:   "broken session payload",
			sess:   session,
			repeat: 15,
			modify: func(t *testing.T, b []byte) SessionReader {
				return bytes.NewReader(b[:50])
			},
			wantErr: true,
			err:     nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var buf byteop.Buffer
			sessionEncodeRepeat(&buf, tt.sess, tt.repeat)

			var encoded SessionReader = &buf
			if tt.modify != nil {
				encoded = tt.modify(t, buf.Bytes())
			}

			repeat, session, err := sessionDecodeRepeat(encoded)
			switch {
			case tt.wantErr && err != nil:
				if tt.err != nil && tt.err != err {
					if !errors.Is(err, tt.err) {
						t.Errorf("unexpected kind of error '%s', want '%s'", err, tt.err)
						return
					}
				}
				testlog.Log(t, errors.Wrap(err, "expected error"))
			case tt.wantErr && err == nil:
				t.Error("decoding error expected")
			case !tt.wantErr && err != nil:
				testlog.Error(t, errors.Wrap(err, "unexpected error"))
			case !tt.wantErr && err == nil:
				if tt.repeat != repeat {
					t.Errorf("unexpected decoded repeat %d, want %d", repeat, tt.repeat)
				}
				if !reflect.DeepEqual(tt.sess, session) {
					t.Errorf("unexpected session data %#v, want %#v", session, tt.sess)
				}
			}
		})
	}
}
