// Code generated by pamgen version (devel). DO NOT EDIT.

package mocks

import (
	"github.com/golang/mock/gomock"
	"github.com/sirkon/deepequal"
	"reflect"
)

// SessionReaderMock interface github.com/sirkon/mpy6a/internal/types.SessionReader mock
type SessionReaderMock struct {
	ctrl     *gomock.Controller
	recorder *SessionReaderMockRecorder
}

// SessionReaderMockRecorder records expected calls of github.com/sirkon/mpy6a/internal/types.SessionReader
type SessionReaderMockRecorder struct {
	mock *SessionReaderMock
}

// NewSessionReaderMock creates SessionReaderMock instance
func NewSessionReaderMock(ctrl *gomock.Controller) *SessionReaderMock {
	mock := &SessionReaderMock{
		ctrl: ctrl,
	}
	mock.recorder = &SessionReaderMockRecorder{mock: mock}
	return mock
}

// EXPECT returns expected calls recorder
func (m *SessionReaderMock) EXPECT() *SessionReaderMockRecorder {
	return m.recorder
}

// Read method to implement github.com/sirkon/mpy6a/internal/types.SessionReader
func (m *SessionReaderMock) Read(p []byte) (n int, err error) {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "Read", p)
	n, _ = ret[0].(int)
	err, _ = ret[1].(error)
	return n, err
}

// Read register expected call of method github.com/sirkon/mpy6a/internal/types.SessionReader.Read
func (mr *SessionReaderMockRecorder) Read(p interface{}) *gomock.Call {
	if p != nil {
		if _, ok := p.(gomock.Matcher); !ok {
			p = deepequal.NewEqMatcher(p)
		}
	}
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "Read", reflect.TypeOf((*SessionReaderMock)(nil).Read), p)
}

// ReadByte method to implement github.com/sirkon/mpy6a/internal/types.SessionReader
func (m *SessionReaderMock) ReadByte() (r byte, err error) {
	m.ctrl.T.Helper()
	ret := m.ctrl.Call(m, "ReadByte")
	r, _ = ret[0].(byte)
	err, _ = ret[1].(error)
	return r, err
}

// ReadByte register expected call of method github.com/sirkon/mpy6a/internal/types.SessionReader.ReadByte
func (mr *SessionReaderMockRecorder) ReadByte() *gomock.Call {
	return mr.mock.ctrl.RecordCallWithMethodType(mr.mock, "ReadByte", reflect.TypeOf((*SessionReaderMock)(nil).ReadByte))
}
