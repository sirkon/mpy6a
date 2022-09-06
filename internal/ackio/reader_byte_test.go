package ackio_test

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"testing"

	"github.com/golang/mock/gomock"
	"github.com/sirkon/mpy6a/internal/ackio"
	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/extmocks"
	"github.com/sirkon/mpy6a/internal/testlog"
)

func ExampleByteReader() {
	var tmpbuf [11]byte
	copy(tmpbuf[:], "a0123456789")

	// Но на входе срезаем последний байт.
	r := ackio.New(bytes.NewReader(tmpbuf[:]), ackio.WithReaderBufferSize(5))
	b := r.ByteReader()

	// Читаем первый символ и подтверждаем вычитку.
	value, err := b.ReadByte()
	if err != nil {
		panic(errors.Wrap(err, "read first character"))
	}
	fmt.Println(string(value))
	fmt.Println(b.Count())
	b.Commit()

	// Читаем текст.
	var dst bytes.Buffer
	if _, err := io.Copy(&dst, io.LimitReader(r, 10)); err != nil {
		panic(errors.Wrap(err, "read the rest"))
	}
	fmt.Println(dst.String())

	// output:
	// a
	// 1
	// 0123456789
}

func TestByteReader(t *testing.T) {
	t.Run("logic error no data source closed", func(t *testing.T) {
		src := bytes.NewReader(nil)
		r := ackio.New(src, ackio.WithReaderBufferSize(3))
		b := r.ByteReader()
		if _, err := binary.ReadUvarint(&b); err != nil {
			if err == io.EOF && b.Count() == 0 {
				testlog.Log(t, b.WrapError(err, "expected error"))
				return
			}

			testlog.Error(t, b.WrapError(err, "unexpected error"))
			return
		}

		t.Error("readout error was expected here")
	})

	t.Run("logic error no data yet", func(t *testing.T) {
		ctrl := gomock.NewController(t)
		m := extmocks.NewReaderMock(ctrl)
		m.EXPECT().Read(gomock.Any()).Return(0, nil)
		r := ackio.New(m)
		b := r.ByteReader()
		if _, err := binary.ReadUvarint(&b); err != nil {
			if ackio.IsReaderNotReady(err) && b.Count() == 0 {
				testlog.Log(t, b.WrapError(err, "expected error"))
				return
			}

			testlog.Error(t, b.WrapError(err, "unexpected error"))
			return
		}

		t.Error("readout error was expected here")
	})

	t.Run("reader error", func(t *testing.T) {
		ctrl := gomock.NewController(t)
		m := extmocks.NewReaderMock(ctrl)
		experr := errors.New("read failed")
		m.EXPECT().Read(gomock.Any()).Return(0, experr)
		r := ackio.New(m)
		b := r.ByteReader()
		if _, err := binary.ReadUvarint(&b); err != nil {
			if errors.Is(err, experr) {
				testlog.Log(t, b.WrapError(err, "expected error"))
				return
			}

			testlog.Error(t, b.WrapError(err, "unexpected error"))
			return
		}

		t.Error("readout error was expected here")
	})

	t.Run("missing uleb128 encoded data", func(t *testing.T) {
		src := bytes.NewReader(uvarintBytes(0xffffffff)[:1])
		r := ackio.New(src, ackio.WithReaderBufferSize(3))
		b := r.ByteReader()
		if _, err := binary.ReadUvarint(&b); err != nil {
			if b.Count() != 0 {
				testlog.Log(t, b.WrapError(err, "expected read uvarint error"))
			}
			return
		}

		t.Error("readout error was expected here")
	})

	t.Run("encoded uvarint data too much", func(t *testing.T) {
		src := bytes.NewReader(bytes.Repeat([]byte{255}, 300))
		r := ackio.New(src, ackio.WithReaderBufferSize(3))
		b := r.ByteReader()
		if _, err := binary.ReadUvarint(&b); err != nil {
			if b.Count() != 0 {
				testlog.Log(t, b.WrapError(err, "expected read uvarint error"))
			}
			return
		}

		t.Error("readout error was expected here")

	})
}

func uvarintBytes(val uint64) []byte {
	var tmpbuf [16]byte
	l := binary.PutUvarint(tmpbuf[:], val)
	return tmpbuf[:l]
}
