package state

import (
	"encoding/binary"
	"io"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/mpio"
	"github.com/sirkon/mpy6a/internal/types"
)

// Decode вычитка данных описаний файлов из предоставленного источника.
func (d *Descriptors) Decode(src mpio.DataReader) error {
	if err := d.decodeSources(src); err != nil {
		return errors.Wrap(err, "decode sources")
	}

	var buf [64]byte
	log, err := d.decodeLog(src, buf[:56])
	if err != nil {
		return errors.Wrap(err, "decode log info")
	}
	d.log = log

	if err := d.decodeUsedSources(src); err != nil {
		return errors.Wrap(err, "decode used sources info")
	}

	if err := d.decodeUsedLogs(src, buf[:]); err != nil {
		return errors.Wrap(err, "decode used logs info")
	}

	return nil
}

func (d *Descriptors) decodeSources(src mpio.DataReader) error {
	noOfSources, err := binary.ReadUvarint(src)
	if err != nil {
		return errors.Wrap(err, "read count of sources")
	}

	d.srcs = make(map[types.Index]*srcDescriptor, int(noOfSources))
	var buf [32]byte
	for i := uint64(0); i < noOfSources; i++ {
		s := srcDescriptor{}
		if _, err := io.ReadFull(src, buf[:]); err != nil {
			return errors.Wrap(err, "read single source data")
		}
		if !types.IndexDecodeCheck(&s.id, buf[:]) {
			return errors.Wrap(errorInvalidIndex, "decode source id")
		}
		s.curPos = binary.LittleEndian.Uint64(buf[16:])
		s.len = binary.LittleEndian.Uint64(buf[24:])
		d.srcs[s.id] = &s
	}

	return nil
}

func (d *Descriptors) decodeLog(src mpio.DataReader, buf []byte) (*logDescriptor, error) {
	var l logDescriptor

	if _, err := io.ReadFull(src, buf); err != nil {
		return nil, errors.Wrap(err, "read log descriptor info")
	}

	if !types.IndexDecodeCheck(&l.id, buf) {
		return nil, errors.Wrap(errorInvalidIndex, "decode id")
	}
	if !types.IndexDecodeCheck(&l.firstID, buf[16:]) {
		return nil, errors.Wrap(errorInvalidIndex, "decode first id")
	}
	if !types.IndexDecodeCheck(&l.lastID, buf[32:]) {
		return nil, errors.Wrap(errorInvalidIndex, "decode last id")
	}
	l.len = binary.LittleEndian.Uint64(buf[48:])

	return &l, nil
}

func (d *Descriptors) decodeUsedSources(src mpio.DataReader) error {
	srcsno, err := binary.ReadUvarint(src)
	if err != nil {
		return errors.Wrap(err, "decode used sources count")
	}

	d.usedSrcs = make([]usedSrc, int(srcsno))
	var buf [24]byte
	for i := uint64(0); i < srcsno; i++ {
		if _, err := io.ReadFull(src, buf[:]); err != nil {
			return errors.Wrap(err, "read used source info").Uint64("used-source-no", i)
		}
		var v usedSrc
		if !types.IndexDecodeCheck(&v.id, buf[:]) {
			return errors.Wrap(errorInvalidIndex, "decode used source index").Uint64("used-source-no", i)
		}
		v.len = binary.LittleEndian.Uint64(buf[16:])
		d.usedSrcs[i] = v
	}

	return nil
}

func (d *Descriptors) decodeUsedLogs(src mpio.DataReader, buf []byte) error {
	logsno, err := binary.ReadUvarint(src)
	if err != nil {
		return errors.Wrap(err, "decode used logs count")
	}

	d.usedLogs = make([]*logDescriptor, int(logsno))
	for i := uint64(0); i < logsno; i++ {
		log, err := d.decodeLog(src, buf[:56])
		if err != nil {
			return errors.Wrap(err, "decode used log info").Uint64("used-log-no", i)
		}
		d.usedLogs[i] = log
	}

	return nil
}
