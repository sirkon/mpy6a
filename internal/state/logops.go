package state

import (
	"encoding/binary"

	"github.com/sirkon/mpy6a/internal/byteop"
	"github.com/sirkon/mpy6a/internal/types"
	"github.com/sirkon/mpy6a/internal/uvarints"
)

func (s *State) logopSessionNew(theme SessionTheme, data []byte) {
	_ = data[0]

	reqlen := 2 + 4 + uvarints.Length(data) + len(data) // 2 байта код + 4 байта тема + длина данных + данные
	buf := byteop.Reuse(s.refCurBuf(), reqlen)

	logopCodeSessionNew.encode(buf)
	binary.LittleEndian.PutUint32(buf[2:], uint32(theme))
	byteop.EncodeBytes(buf[6:], data)
}

func (s *State) logopSessionAppend(sessionID types.Index, data []byte) {
	_ = 1 / sessionID.Term
	_ = data[0]

	reqlen := 2 + 16 + uvarints.Length(data) + len(data) // 2 байта код + 16 байт индекс сессии + длина данных + данные
	buf := byteop.Reuse(s.refCurBuf(), reqlen)

	logopCodeSessionAppend.encode(buf)
	sessionID.encode(buf[2:])
	byteop.EncodeBytes(buf[18:], data)
}

func (s *State) logopSessionRewrite(sessionID types.Index, data []byte) {
	_ = 1 / sessionID.Term
	_ = data[0]

	reqlen := 2 + 16 + uvarints.Length(data) + len(data) // 2 байта код + 16 байт индекс сессии + длина данных + данные
	buf := byteop.Reuse(s.refCurBuf(), reqlen)

	logopCodeSessionRewrite.encode(buf)
	sessionID.encode(buf[2:])
	byteop.EncodeBytes(buf[18:], data)
}

func (s *State) logopSessionFinish(sessionID types.Index) {
	_ = 1 / sessionID.Term

	reqlen := 2 + 16 // 4 байта код + 16 байт индекс сессии
	buf := byteop.Reuse(s.refCurBuf(), reqlen)

	logopCodeSessionFinish.encode(buf)
	sessionID.encode(buf[2:])
}

func (s *State) logopSessionSaveFixedTimeout(sessionID types.Index, repeatAfter uint64, ftStateID types.Index, ftTimeout uint32) {
	_ = 1 / sessionID.Term
	_ = 1 / ftStateID.Term

	reqlen := 2 + 16 + 8 + 2 + 16 + 4
	buf := byteop.Reuse(s.refCurBuf(), reqlen)

	logopCodeSessionSave.encode(buf)
	sessionID.encode(buf[2:])
	binary.LittleEndian.PutUint64(buf[18:], repeatAfter)
	logopSavedDestCodeFixedTimeout.encode(buf[26:])
	ftStateID.encode(buf[28:])
	binary.LittleEndian.PutUint32(buf[44:], ftTimeout)
}

func (s *State) logopSessionSaveMemory(sessionID types.Index, repeatAfter uint64) {
	_ = 1 / sessionID.Term

	reqlen := 2 + 16 + 8 + 2
	buf := byteop.Reuse(s.refCurBuf(), reqlen)

	logopCodeSessionSave.encode(buf)
	sessionID.encode(buf[2:])
	binary.LittleEndian.PutUint64(buf[18:], repeatAfter)
	logopSavedDestCodeMemory.encode(buf[26:])
}

func (s *State) logopSessionRepeatFromFixedTimeout(ftStateID types.Index, ftTimeout uint32) {
	_ = 1 / ftStateID.Term

	reqlen := 2 + 2 + 16 + 4
	buf := byteop.Reuse(s.refCurBuf(), reqlen)

	logopCodeSessionRepeat.encode(buf)
	logopSavedSourceCodeFixedTimeout.encode(buf[2:])
	ftStateID.encode(buf[4:])
	binary.LittleEndian.PutUint32(buf[20:], ftTimeout)
}

func (s *State) logopSessionRepeatFromSnapshot(sStateID types.Index) {
	_ = 1 / sStateID.Term

	reqlen := 2 + 2 + 16
	buf := byteop.Reuse(s.refCurBuf(), reqlen)

	logopCodeSessionRepeat.encode(buf)
	logopSavedSourceCodeSnapshot.encode(buf[2:])
	sStateID.encode(buf[4:])
}

func (s *State) logopSessionRepeatFromSnapshotLength(sStateID types.Index, length uint32) {
	_ = 1 / sStateID.Term

	reqlen := 2 + 2 + 16 + 4
	buf := byteop.Reuse(s.refCurBuf(), reqlen)

	logopCodeSessionRepeat.encode(buf)
	logopSavedSourceCodeSnapshot.encode(buf[2:])
	sStateID.encode(buf[4:])
	binary.LittleEndian.PutUint32(buf[20:], length)
}

func (s *State) logopSessionRepeatFromMerged(mStateID types.Index) {
	_ = 1 / mStateID.Term

	reqlen := 2 + 2 + 16
	buf := byteop.Reuse(s.refCurBuf(), reqlen)

	logopCodeSessionRepeat.encode(buf)
	logopSavedSourceCodeMerged.encode(buf[2:])
	mStateID.encode(buf[4:])
}

func (s *State) logopSessionRepeatFromMergedLength(mStateID types.Index, length uint32) {
	_ = 1 / mStateID.Term

	reqlen := 2 + 2 + 16 + 4
	buf := byteop.Reuse(s.refCurBuf(), reqlen)

	logopCodeSessionRepeat.encode(buf)
	logopSavedSourceCodeMerged.encode(buf[2:])
	mStateID.encode(buf[4:])
	binary.LittleEndian.PutUint32(buf[20:], length)
}

func (s *State) logopSessionRepeatFromMemory() {
	reqlen := 2 + 2
	buf := byteop.Reuse(s.refCurBuf(), reqlen)

	logopCodeSessionRepeat.encode(buf)
	logopSavedSourceCodeMemory.encode(buf[2:])
}

func (s *State) logopSessionRepeatFromMemoryLength(length uint32) {
	reqlen := 2 + 2 + 4
	buf := byteop.Reuse(s.refCurBuf(), reqlen)

	logopCodeSessionRepeat.encode(buf)
	logopSavedSourceCodeMemory.encode(buf[2:])
	binary.LittleEndian.PutUint32(buf[4:], length)
}

func (s *State) logopAsyncStartSnapshotCreate() {
	reqlen := 2 + 2
	buf := byteop.Reuse(s.refCurBuf(), reqlen)

	logopCodeAsyncStart.encode(buf)
	logopAsyncCodeSnapshotCreate.encode(buf[2:])
}

func (s *State) logopAsyncStartLogRotate() {
	reqlen := 2 + 2
	buf := byteop.Reuse(s.refCurBuf(), reqlen)

	logopCodeAsyncStart.encode(buf)
	logopAsyncCodeLogRotate.encode(buf[2:])
}

func (s *State) logopAsyncStartMerge(sources []mergeSource) {
	// Длина списка источников слияний должна быть больше 1.
	_ = 1 / len(sources)
	_ = 1 / (len(sources) - 1)

	reqlen := 2 + 2 + len(sources)*(2+16)
	buf := byteop.Reuse(s.refCurBuf(), reqlen)

	logopCodeAsyncStart.encode(buf)
	logopAsyncCodeMerge.encode(buf[2:])

	buf = buf[4:]
	for _, src := range sources {
		switch src.code {
		case logopSavedSourceCodeSnapshot, logopSavedSourceCodeMerged:
		default:
			panic(src.code)
		}
		_ = 1 / src.stateID.Term

		src.code.encode(buf)
		src.stateID.encode(buf[2:])
		buf = buf[2+16:]
	}
}

func (s *State) logopAsyncStartFixedTimeoutRotation(timeout uint32) {
	reqlen := 2 + 2 + 4
	buf := byteop.Reuse(s.refCurBuf(), reqlen)

	logopCodeAsyncStart.encode(buf)
	logopAsyncCodeFixedTimeoutRotation.encode(buf[2:])
	binary.LittleEndian.PutUint32(buf[4:], timeout)
}

func (s *State) logopAsyncCommit(id types.Index) {
	_ = 1 / id.Term

	reqlen := 2 + 16
	buf := byteop.Reuse(s.refCurBuf(), reqlen)

	logopCodeAsyncCommit.encode(buf)
	id.encode(buf[2:])
}

func (s *State) logopAsyncCancel(id types.Index) {
	_ = 1 / id.Term

	reqlen := 2 + 16
	buf := byteop.Reuse(s.refCurBuf(), reqlen)

	logopCodeAsyncCancel.encode(buf)
	id.encode(buf[2:])
}

func (s *State) refCurBuf() *[]byte {
	return &s.logbuf[s.logcur%cap(s.logbuf)]
}

type logopCodeType uint16

const (
	logopCodeSessionNew logopCodeType = iota
	logopCodeSessionAppend
	logopCodeSessionRewrite
	logopCodeSessionFinish
	logopCodeSessionSave
	logopCodeSessionRepeat
	logopCodeAsyncStart
	logopCodeAsyncCommit
	logopCodeAsyncCancel
)

func (c logopCodeType) encode(buf []byte) {
	binary.LittleEndian.PutUint16(buf, uint16(c))
}

type logopSavedDestCodeType uint16

const (
	logopSavedDestCodeMemory logopSavedDestCodeType = iota
	logopSavedDestCodeFixedTimeout
)

func (c logopSavedDestCodeType) encode(buf []byte) {
	binary.LittleEndian.PutUint16(buf, uint16(c))
}

type logopSavedSourceCodeType uint32

const (
	logopSavedSourceCodeSnapshot logopSavedSourceCodeType = iota
	logopSavedSourceCodeMerged
	logopSavedSourceCodeMemory
	logopSavedSourceCodeFixedTimeout
)

type logopAsyncCodeType uint16

func (c logopSavedSourceCodeType) encode(buf []byte) {
	binary.LittleEndian.PutUint16(buf, uint16(c))
}

const (
	logopAsyncCodeSnapshotCreate logopAsyncCodeType = iota
	logopAsyncCodeLogRotate
	logopAsyncCodeMerge
	logopAsyncCodeFixedTimeoutRotation
)

type isOperationAsyncDescriptorType struct{}

func (*isOperationAsyncDescriptorType) isOperationAsync() {}

func (c logopAsyncCodeType) encode(buf []byte) {
	binary.LittleEndian.PutUint16(buf, uint16(c))
}

type mergeSource struct {
	code    logopSavedSourceCodeType
	stateID types.Index
}
