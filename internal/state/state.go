package state

import (
	"strconv"
	"sync"

	"github.com/sirkon/mpy6a/internal/storage"
	"github.com/sirkon/mpy6a/internal/types"
)

// State данные состояния
type State struct {
	index     types.Index
	snapIndex types.Index

	// Статистика текущих данных
	stats stats

	// Базовые ограничения
	limits limits

	// Данные сессий в оперативной памяти.
	saved  *memorySavedSessions
	active map[types.Index]*types.Session
	fixeds map[uint32]*fixedTimeoutFile

	// Кольцевой буфер с последними элементами лога.
	logbuf [][]byte
	logcur int

	policies PoliciesProvider

	// Дескрипторы файлов сессий для создания слепка.
	descriptors *stateFilesDescriptors
	mgreader    *sourceReaderGlobal
	rdl         sync.Mutex // лок захватываемый при поиске новых сессий для повтора

	// Индекс последнего слепка.
	lastSnapshot types.Index

	snlog      *storage.snapshotLog
	log        *storage.oplog
	sessionBuf []byte

	// workslot получение права на проведение работы
	workslot chan struct{}

	logger Logger

	asyncArtifacts struct {
		newlog *storage.oplog
		ft     map[uint32]*fixedTimeoutFile
	}
}

type stats struct {
	activeLength uint64
}

type limits struct {
	sessionLength     uint64
	snapshotLogLength uint64
	logFrameSize      uint64
	sources           int
}

func (s *State) curBuf() []byte {
	return s.logbuf[s.logcur%cap(s.logbuf)]
}

func (s *State) snapshotName(stateID types.Index) string {
	return "snapshot-" + stateID.String() + ".data"
}

func (s *State) mergedName(stateID types.Index) string {
	return "merged-" + stateID.String() + ".data"
}

func (s *State) fixedTimeoutName(stateID types.Index, to int) string {
	return "fixed-timeout-" + strconv.Itoa(to) + "-" + stateID.String() + ".data"
}

func (s *State) logName(stateID types.Index) string {
	return stateID.String() + ".log"
}

func (s *State) snapshotLog() string {
	return "snapshot.log"
}
