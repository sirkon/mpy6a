package fileregistry

// Stats общая статистика хранилища.
type Stats struct {
	// FileCount общее число зарегистрированный файлов.
	FileCount int
	// FileUsed число используемых в данный момент файлов.
	FileUsed int
	// TotalSize общий размер всех файлов.
	TotalSize uint64
	// UsedSize общий размер используемых в данный момент файлов.
	UsedSize uint64

	Logs        usedFilesInfo
	Snapshots   usedFilesInfo
	Merges      usedFilesInfo
	Fixeds      usedFilesInfo
	Temporaries int
}

type usedFilesInfo struct {
	Count int
	Size  uint64
}

func (s *Stats) addFile() {
	s.FileCount++
	s.FileUsed++
}

func (s *Stats) addData(c uint64) {
	s.TotalSize += c
	s.UsedSize += c
}
