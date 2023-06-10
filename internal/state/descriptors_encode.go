package state

import (
	"encoding/binary"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/mpio"
	"github.com/sirkon/mpy6a/internal/types"
	"github.com/sirkon/mpy6a/internal/uvarints"
)

// Encode сброс данных описаний файлов в предоставленный приёмник.
func (d *Descriptors) Encode(dst mpio.DataWriter) error {
	if err := d.encodeSources(dst); err != nil {
		return errors.Wrap(err, "encode sources info")
	}

	var buf [64]byte
	if err := d.encodeLog(dst, buf[:], d.log); err != nil {
		return errors.Wrap(err, "encode log info")
	}

	if err := d.encodeUsedSrcs(dst); err != nil {
		return errors.Wrap(err, "encode used sources info")
	}

	if err := d.encodeUsedLogs(dst, buf[:]); err != nil {
		return errors.Wrap(err, "encode used logs info")
	}

	return nil
}

func (d *Descriptors) encodeSources(dst mpio.DataWriter) error {
	if _, err := uvarints.Write(dst, uint64(len(d.srcs))); err != nil {
		return errors.Wrap(err, "write sources count")
	}

	var buf [32]byte
	for _, descr := range d.srcs {
		types.IndexEncode(buf[:16], descr.id)
		binary.LittleEndian.PutUint64(buf[16:24], descr.curPos)
		binary.LittleEndian.PutUint64(buf[24:32], descr.len)
		if _, err := dst.Write(buf[:32]); err != nil {
			return errors.Wrap(err, "write descriptor").Stg("descriptor-id", descr.id)
		}
	}

	return nil
}

func (d *Descriptors) encodeLog(dst mpio.DataWriter, buf []byte, l *logDescriptor) error {
	types.IndexEncode(buf[:], l.id)
	types.IndexEncode(buf[16:], l.firstID)
	types.IndexEncode(buf[32:], l.lastID)
	binary.LittleEndian.PutUint64(buf[48:], l.len)

	if _, err := dst.Write(buf[:56]); err != nil {
		return err
	}

	return nil
}

func (d *Descriptors) encodeUsedSrcs(dst mpio.DataWriter) error {
	if _, err := uvarints.Write(dst, uint64(len(d.usedSrcs))); err != nil {
		return errors.Wrap(err, "encode used sources count")
	}

	var buf [24]byte
	for _, src := range d.usedSrcs {
		types.IndexEncode(buf[:], src.id)
		binary.LittleEndian.PutUint64(buf[16:], src.len)
		if _, err := dst.Write(buf[:]); err != nil {
			return errors.Wrap(err, "encode used source").Stg("used-source-id", src.id)
		}
	}

	return nil
}

func (d *Descriptors) encodeUsedLogs(dst mpio.DataWriter, buf []byte) error {
	if _, err := uvarints.Write(dst, uint64(len(d.usedLogs))); err != nil {
		return errors.Wrap(err, "encode used logs count")
	}

	for _, l := range d.usedLogs {
		if err := d.encodeLog(dst, buf, l); err != nil {
			return errors.Wrap(err, "write used log info").Stg("used-log-id", l.id)
		}
	}

	return nil
}
