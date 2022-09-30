package logio

const (
	// fileMetaInfoHeaderSize размер метаданных в начале файла.
	fileMetaInfoHeaderSize = 16

	// frameSizeHardLimit максимальный размер кадра не должен превышать 32Мб.
	frameSizeHardLimit = 1024 * 1024 * 32 // 32Мб

	// defaultBufferCapacityInEvents количество событий которое помещается в буфер по-умолчанию.
	defaultBufferCapacityInEvents = 256

	// reasonableBufferCapacityInEvents минимальное количество событий которое должно помещаться в буфер.
	reasonableBufferCapacityInEvents = 5
)
