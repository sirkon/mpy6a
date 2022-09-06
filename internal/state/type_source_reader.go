package state

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"github.com/sirkon/mpy6a/internal/byteop"
	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/types"
	"github.com/sirkon/mpy6a/internal/uvarints"
)

// sourceReader абстракция для вычитки сессий из источников.
type sourceReader interface {
	fmt.Stringer

	// Read получить очередную сессию из источника.
	// err == io.EOF означает полную вычитку источника.
	// Session == nil && err == nil означает отсутствие данных на текущий
	//  момент.
	Read() (uint64, *types.Session, error)
	// Commit подтвердить вычитку очередной сессии из источника.
	Commit(s *State)
	// Report сформировать дескрипторы источников в состоянии.
	Report(s *State)
	// MakeLog сформировать запись лога соответствующую записи.
	MakeLog(s *State)
	// Close закрыть источник чтения.
	Close() error
}

// sourceReaderGlobal объединение всех источников вычитки сохранённых
// сессий в один с таким же интерфейсом.
type sourceReaderGlobal struct {
	sources    []sourceReader
	altSources []sourceReader

	mergeds map[types.Index]*sourceReaderMerged
	snaps   map[types.Index]*sourceReaderSnapshot

	last   lastSessionReadState
	reader sourceReader
}

func (r *sourceReaderGlobal) String() string {
	return "combined source reader"
}

func (r *sourceReaderGlobal) read() (repeat uint64, sess *types.Session, reader sourceReader, err error) {
	if len(r.sources) == 0 {
		return 0, nil, nil, nil
	}

	r.altSources = r.altSources[:0]
	for _, src := range r.sources {
		rep, ses, err := src.Read()
		if err != nil {
			if err == io.EOF {
				if err := src.Close(); err != nil {
					return 0, nil, nil,
						errors.Wrap(err, "Close source").
							Stg("exhausted-source", src)
				}
				continue
			}

			return 0, nil, nil,
				errors.Wrap(err, "Read source").Stg("failed-source", src)
		}

		r.altSources = append(r.altSources, src)

		if rep > 0 {
			if repeat == 0 || rep < repeat {
				repeat, sess, r.reader = rep, ses, src
				continue
			}
		}
	}

	r.sources, r.altSources = r.altSources, r.sources

	return repeat, sess, r.reader, nil
}

func (r *sourceReaderGlobal) reportState(s *State) {
	for _, src := range r.sources {
		src.Report(s)
	}
}

func (r *sourceReaderGlobal) close() error {
	return nil
}

func (r *sourceReaderGlobal) append(src sourceReader) {
	r.sources = append(r.sources, src)
}

func (r *sourceReaderGlobal) appendMerged(src *sourceReaderMerged) {
	r.sources = append(r.sources, src)
	r.mergeds[src.id] = src
}

func (r *sourceReaderGlobal) appendSnapshot(src *sourceReaderSnapshot) {
	r.sources = append(r.sources, src)
	r.snaps[src.id] = src
}

func (r *sourceReaderGlobal) underAsyncOp(id types.Index) {
	if v, ok := r.mergeds[id]; ok {
		v.isMergeSource = true
		return
	}

	if v, ok := r.snaps[id]; ok {
		v.isMergeSource = true
	}
}

func (s *State) sourceReaderFixedTimeoutFromConcurrent(to uint32) (*sourceReaderFixedTimeout, error) {
	v, ok := s.fixeds[to]
	if !ok {
		return nil, errorInternalNoTimeoutSupport(int(to))
	}

	res := &sourceReaderFixedTimeout{
		src:         v,
		to:          to,
		commitedPos: v.rfpos,
	}
	res.last.commited = true
	return res, nil
}

func (s *State) sourceReaderFixedTimeout(id types.Index, start, finish uint64, to uint32) (*sourceReaderFixedTimeout, error) {
	file, err := os.Open(s.fixedTimeoutName(id, int(to)))
	if err != nil {
		return nil, errors.Wrap(err, "open fixed timeout file")
	}

	v, err := newConcurrentFile(id, nil, file, finish, start, uint64(len(s.sessionBuf)))
	if err != nil {
		return nil, errors.Wrap(err, "setup fixed timeout reader")
	}

	res := &sourceReaderFixedTimeout{
		src:         v,
		to:          to,
		commitedPos: v.rfpos,
	}
	res.last.commited = true
	return res, nil
}

func (s *State) sourceReaderMerged(id types.Index, start uint64) (res *sourceReaderMerged, err error) {
	file, err := os.Open(s.mergedName(id))
	if err != nil {
		return nil, errors.Wrap(err, "open merged file as a source")
	}

	defer func() {
		if err == nil {
			return
		}

		if err := file.Close(); err != nil {
			s.logger.Error(errors.Wrap(err, "Close merged file after an error").Str(
				"merged-file-name",
				s.mergedName(id),
			))
		}
	}()

	if _, err := file.Seek(int64(start), 0); err != nil {
		return nil, errors.Wrap(err, "seek to the start")
	}

	res = &sourceReaderMerged{
		id:   id,
		pos:  start,
		src:  bufio.NewReader(file),
		file: file,
	}
	res.last.commited = true
	return res, nil
}

func (s *State) sourceReaderSnapshot(id types.Index, start uint64) (_ *sourceReaderSnapshot, err error) {
	name := s.snapshotName(id)
	file, err := os.Open(name)
	if err != nil {
		return nil, errors.Wrap(err, "open snapshot file as a source")
	}

	defer func() {
		if err == nil {
			return
		}

		if cErr := file.Close(); cErr != nil {
			s.logger.Error(
				errors.Wrap(cErr, "Close snapshot file after an error").
					Str("snapshot-file-name", name),
			)
		}
	}()

	var buf [8]byte
	if _, err := io.ReadFull(file, buf[:8]); err != nil {
		return nil, errors.Wrap(err, "Read saved sessions length")
	}
	finish := binary.LittleEndian.Uint64(buf[:8]) + 8

	if start == 0 {
		start = 8
	}

	if _, err := file.Seek(int64(int(start)), 0); err != nil {
		return nil, errors.Wrap(err, "seek to the start position")
	}

	res := &sourceReaderSnapshot{
		id:   id,
		file: file,
		src:  bufio.NewReader(io.LimitReader(file, int64(finish-start))),
		pos:  start,
		end:  finish + 8,
	}
	res.last.commited = true

	return res, nil
}

func (s *State) sourceReaderMemory() *sourceReaderMemory {
	return &sourceReaderMemory{
		s: s,
	}
}

type sourceReaderFixedTimeout struct {
	src *fixedTimeoutFile

	last        lastSessionReadState
	to          uint32
	commitedPos uint64
}

func (r *sourceReaderFixedTimeout) String() string {
	var b strings.Builder
	b.WriteString("fixed-timeout[")
	b.WriteString(r.src.id.String())
	b.WriteByte(',')
	b.WriteString(strconv.Itoa(int(r.to)))
	b.WriteString("s]")

	return b.String()
}

func (r *sourceReaderFixedTimeout) Read() (uint64, *types.Session, error) {
	if !r.last.commited {
		return r.last.repeat, r.last.session, nil
	}

	repeat, sessbytes, err := r.src.ReadSession()
	if err != nil {
		if err == io.EOF {
			return 0, nil, io.EOF
		}

		return 0, nil, errors.Wrap(err, "Read next Session")
	}

	if len(sessbytes) == 0 {
		// Новых данных пока нет.
		return 0, nil, nil
	}

	sess, err := decodeSession(sessbytes)
	if err != nil {
		return 0, nil, errors.Wrap(err, "decode fixed timeout Session")
	}

	r.last.repeat = repeat
	r.last.session = sess

	return repeat, sess, err
}

func (r *sourceReaderFixedTimeout) Commit(s *State) {
	r.last.commited = true
	r.commitedPos = r.src.rfpos
}

func (r *sourceReaderFixedTimeout) Report(s *State) {
	s.descriptors.fixedTimeouts[r.src.id] = &fileRangeDescriptor{
		id:     r.src.id,
		start:  r.commitedPos,
		finish: r.src.wtotal,
	}
}

func (r *sourceReaderFixedTimeout) MakeLog(s *State) {
	s.logopSessionRepeatFromFixedTimeout(r.src.id, r.to)
}

func (r *sourceReaderFixedTimeout) Close() error {
	return r.src.CloseRead()
}

type sourceReaderMemory struct {
	s *State

	last lastSessionReadState
}

func (r *sourceReaderMemory) String() string {
	return "memory"
}

func (r *sourceReaderMemory) Read() (uint64, *types.Session, error) {
	repeat, data := r.s.saved.First()
	if len(data) == 0 {
		return 0, nil, nil
	}

	sess, err := decodeSession(data)
	if err != nil {
		return 0, nil, errors.Wrap(err, "decode Session data")
	}

	r.last.session = sess
	r.last.datalen = sess.storageLen()

	return repeat, sess, nil
}

func (r *sourceReaderMemory) Commit(s *State) {
	r.s.saved.FirstCommit()

	if s.descriptors.snapshotIncoming == nil {
		return
	}

	if s.descriptors.snapshotIncoming.id.before(r.last.session.lastIndex) {
		return
	}

	s.descriptors.snapshotIncoming.start += uint64(r.last.datalen)
}

func (r *sourceReaderMemory) MakeLog(s *State) {
	if s.descriptors.snapshotIncoming == nil {
		s.logopSessionRepeatFromMemory()
		return
	}

	if s.descriptors.snapshotIncoming.id.before(r.last.session.lastIndex) {
		s.logopSessionRepeatFromMemory()
		return
	}

	s.logopSessionRepeatFromMemoryLength(uint32(r.last.datalen))
}

func (r *sourceReaderMemory) Report(s *State) {}

func (r *sourceReaderMemory) Close() error {
	return nil
}

type lastSessionReadState struct {
	repeat  uint64
	session *types.Session

	commited bool
	datalen  int
}

type sourceReaderMerged struct {
	id  types.Index
	pos uint64

	src  *bufio.Reader
	file *os.File

	buf []byte

	last          lastSessionReadState
	isMergeSource bool
}

func (r *sourceReaderMerged) String() string {
	var b strings.Builder

	b.WriteString("merged[")
	b.WriteString(r.id.String())
	b.WriteByte(']')
	return b.String()
}

func (r *sourceReaderMerged) Read() (uint64, *types.Session, error) {
	if !r.last.commited {
		return r.last.repeat, r.last.session, nil
	}

	var buf [8]byte
	if _, err := io.ReadFull(r.src, buf[:8]); err != nil {
		if err == io.EOF {
			return 0, nil, io.EOF
		}

		return 0, nil, errors.Wrap(err, "Read Session repeat time")
	}

	sesslen, err := binary.ReadUvarint(r.src)
	if err != nil {
		return 0, nil, errors.Wrap(err, "Read Session length")
	}

	dst := byteop.Reuse(&r.buf, int(sesslen))
	if _, err := io.ReadFull(r.src, dst); err != nil {
		return 0, nil, errors.Wrap(err, "Read Session data")
	}

	session, err := decodeSession(dst)
	if err != nil {
		return 0, nil, errors.Wrap(err, "decode Session data")
	}

	r.last.repeat = binary.LittleEndian.Uint64(buf[:8])
	r.last.session = session
	r.last.commited = false
	r.last.datalen = 8 + uvarints.LengthInt(sesslen) + int(sesslen)

	return r.last.repeat, r.last.session, nil
}

func (r *sourceReaderMerged) Commit(stat *State) {
	r.last.commited = true
	r.pos += uint64(r.last.datalen)
	if r.isMergeSource {
		stat.descriptors.mergeIncoming.start += uint64(r.last.datalen)
	}
}

func (r *sourceReaderMerged) Report(stat *State) {
	stat.descriptors.merges[r.id] = &fileRangeDescriptor{
		start: r.pos,
	}
}

func (r *sourceReaderMerged) MakeLog(s *State) {
	if r.isMergeSource {
		s.logopSessionRepeatFromMergedLength(r.id, uint32(r.last.datalen))
	} else {
		s.logopSessionRepeatFromMerged(r.id)
	}
}

func (r *sourceReaderMerged) Close() error {
	if err := r.file.Close(); err != nil {
		return err
	}

	return nil
}

// sourceReaderSnapshot вычитка сессий из слепков.
type sourceReaderSnapshot struct {
	id   types.Index
	file *os.File
	src  *bufio.Reader
	pos  uint64
	end  uint64
	buf  []byte

	last          lastSessionReadState
	isMergeSource bool
}

func (r *sourceReaderSnapshot) String() string {
	var b strings.Builder

	b.WriteString("snapshot[")
	b.WriteString(r.id.String())
	b.WriteByte(']')
	return b.String()
}

func (r *sourceReaderSnapshot) Read() (uint64, *types.Session, error) {
	if !r.last.commited {
		return r.last.repeat, r.last.session, nil
	}

	var buf [8]byte
	if _, err := io.ReadFull(r.src, buf[:8]); err != nil {
		if err == io.EOF {
			return 0, nil, io.EOF
		}

		return 0, nil, errors.Wrap(err, "Read Session repeat time")
	}

	sesslen, err := binary.ReadUvarint(r.src)
	if err != nil {
		return 0, nil, errors.Wrap(err, "Read Session length")
	}

	dst := byteop.Reuse(&r.buf, int(sesslen))
	if _, err := io.ReadFull(r.src, dst); err != nil {
		return 0, nil, errors.Wrap(err, "Read Session data")
	}

	session, err := decodeSession(dst)
	if err != nil {
		return 0, nil, errors.Wrap(err, "decode Session data")
	}

	r.last.repeat = binary.LittleEndian.Uint64(buf[:8])
	r.last.session = session
	r.last.commited = false
	r.last.datalen = 8 + uvarints.LengthInt(sesslen) + int(sesslen)

	return r.last.repeat, r.last.session, nil
}

func (r *sourceReaderSnapshot) Commit(s *State) {
	r.last.commited = true
	r.pos += uint64(r.last.datalen)

	if r.isMergeSource {
		s.descriptors.mergeIncoming.start += uint64(r.last.datalen)
	}
}

func (r *sourceReaderSnapshot) Report(stat *State) {
	stat.descriptors.snapshots[r.id] = &fileRangeDescriptor{
		start:  r.pos,
		finish: r.end,
	}
}

func (r *sourceReaderSnapshot) Close() error {
	if err := r.file.Close(); err != nil {
		return err
	}

	return nil
}

func (r *sourceReaderSnapshot) MakeLog(stat *State) {
	if r.isMergeSource {
		stat.logopSessionRepeatFromSnapshotLength(r.id, uint32(r.last.datalen))
	} else {
		stat.logopSessionRepeatFromSnapshot(r.id)
	}
}

var (
	_ sourceReader = new(sourceReaderMemory)
	_ sourceReader = new(sourceReaderFixedTimeout)
	_ sourceReader = new(sourceReaderMerged)
	_ sourceReader = new(sourceReaderSnapshot)
)
