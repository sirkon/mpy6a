package options

func _() {
	var data [1]struct{}
	data[SimReaderBufferSize-SimWriterBufferSize] = struct{}{}
	data[SimReaderBufferSize-BufReaderBufferSize] = struct{}{}
	data[SimReaderBufferSize-4096] = struct{}{}
}
