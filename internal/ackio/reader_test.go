package ackio_test

import (
	"bytes"
	"fmt"
	"io"
	"testing"

	"github.com/golang/mock/gomock"
	"github.com/sirkon/mpy6a/internal/ackio"
	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/extmocks"
	"github.com/sirkon/mpy6a/internal/testlog"
)

func ExampleReader() {
	source := bytes.NewReader([]byte("Hello World!"))
	r := ackio.New(
		source,
		ackio.WithFrameSize(3),
		ackio.WithReaderBufferSize(5),
		ackio.WithReaderSourcePosition(5),
	)

	// Читаем полностью и выводим прочитанное.
	var buf [3]byte
	var res bytes.Buffer
	for {
		read, err := r.Read(buf[:])
		if err != nil {
			if err == io.EOF {
				if read > 0 {
					res.Write(buf[:read])
				}

				break
			}

			panic(errors.Wrap(err, "do first readout"))
		}

		res.Write(buf[:read])
	}
	fmt.Println(res.String())

	// Подтверждаем чтение на позицию прямо перед "World!" и откатываемся на неё.
	if err := r.Ack(len("Hello ")); err != nil {
		panic(errors.Wrap(err, "acknowledge after the first readout"))
	}
	r.Rollback()

	// Делаем вторую полную вычитку и выводим снова.
	res.Reset()
	for {
		read, err := r.Read(buf[:])
		if err != nil {
			if err == io.EOF {
				if read > 0 {
					res.Write(buf[:read])
				}

				break
			}

			panic(errors.Wrap(err, "do second readout"))
		}

		res.Write(buf[:read])
	}
	fmt.Println(res.String())

	// Показываем логическую позицию в источнике.
	fmt.Println(r.Pos())

	// output:
	// Hello World!
	// World!
	// 11
}

func TestReader(t *testing.T) {
	t.Run("positive-1", func(t *testing.T) {
		// Сценарий:
		//   1. Вычитываем всё содержимое до EOF
		//   2. Сбрасываем (Rollback)
		//   3. Вычитываем ещё раз кроме последних двух байт.
		//   4. Подтверждаем всё вычитанное на предыдущем шаге.
		//   5. Читаем байт.
		//   6. Сбрасываем.
		//   7. Читаем до конца.
		//   8. Читаем и получаем EOF.

		ctrl := gomock.NewController(t)
		m := extmocks.NewReaderMock(ctrl)

		r := ackio.New(
			m,
			ackio.WithFrameSize(3),
			ackio.WithReaderBufferSize(5),
			ackio.WithReaderSourcePosition(5),
		)

		const want = "Hello World"
		source := want
		doReturner := func(dst []byte) (int, error) {
			if source == "" {
				return 0, io.EOF
			}

			if len(source) <= len(dst) {
				copy(dst, source)
				l := len(source)
				source = ""
				return l, io.EOF
			}

			copy(dst, source[:len(dst)])
			source = source[len(dst):]
			return len(dst), nil
		}
		m.EXPECT().Read(gomock.Any()).DoAndReturn(doReturner).Times(3)

		// Шаг 1.
		var b bytes.Buffer
		if _, err := io.Copy(&b, r); err != nil {
			testlog.Error(t, errors.Wrap(err, "read data"))
			return
		}

		if b.String() != want {
			t.Errorf("expected '%s' got '%s'", want, b.String())
			return
		}

		// Шаги 2-3
		r.Rollback()
		buf := make([]byte, len(want)-2)
		read, err := io.ReadFull(r, buf)
		if err != nil {
			testlog.Error(t, errors.Wrap(err, "read everything besides two last bytes"))
			return
		}
		if read != len(want)-2 {
			testlog.Error(
				t,
				errors.New("unexpected read length").
					Int("want", len(want)-2).
					Int("unexpected-length", read),
			)
			return
		}
		if string(buf) != want[:len(want)-2] {
			testlog.Error(
				t,
				errors.New("unexpected reread content").
					Str("want", want[:len(want)-2]).
					Str("got", string(buf)),
			)
			return
		}

		// Шаги 4-6
		if err := r.Ack(len(want) - 2); err != nil {
			testlog.Error(t, errors.Wrap(err, "acknowledge everything except last two bytes"))
			return
		}
		if r.Pos() != int64(len(want)-2+5) {
			testlog.Error(
				t,
				errors.Wrap(err, "unexpected position after first ack").
					Int("want", len(want)-2+5).
					Int64("unexpected-position", r.Pos()),
			)
			return
		}

		var tmpbuf [8]byte
		read, err = r.Read(tmpbuf[:1])
		if err != nil {
			testlog.Error(t, errors.Wrap(err, "read the byte before the last"))
			return
		}
		if read != 1 {
			testlog.Error(
				t,
				errors.New("unexpected bytes count").
					Int("want", 1).
					Int("unexpected-count", read),
			)
			return
		}
		if err := checkBytes(tmpbuf[:1], "l"); err != nil {
			testlog.Error(t, errors.Wrap(err, "unexpected byte before the last value"))
			return
		}
		r.Rollback()

		// Шаги 7-8
		read, err = r.Read(tmpbuf[:])
		if err != nil {
			testlog.Error(t, errors.Wrap(err, "read last two bytes"))
			return
		}
		if err := checkBytes(tmpbuf[:read], "ld"); err != nil {
			testlog.Error(t, errors.Wrap(err, "read last two bytes"))
			return
		}
		if err := r.Ack(2); err != nil {
			testlog.Error(t, errors.Wrap(err, "acknowledge the rest"))
			return
		}
		if r.Pos() != int64(len(want)+5) {
			testlog.Error(
				t,
				errors.New("unexpected position after everything was acked").
					Int("want", len(want)+5).
					Int64("unexpected-position", r.Pos()),
			)
			return
		}
	})

	t.Run("positive-2", func(t *testing.T) {
		// В этом сценарии проверяем получение io.EOF
		ctrl := gomock.NewController(t)
		m := extmocks.NewReaderMock(ctrl)

		r := ackio.New(
			m,
			ackio.WithFrameSize(3),
			ackio.WithReaderBufferSize(5),
			ackio.WithReaderSourcePosition(5),
		)

		m.EXPECT().Read(gomock.Any()).Return(0, io.EOF)

		var tmpbuf [8]byte
		read, err := r.Read(tmpbuf[:])
		if err != nil {
			if err != io.EOF {
				testlog.Error(t, errors.Wrap(err, "read"))
			}
			if read != 0 {
				testlog.Error(
					t,
					errors.New("unexpected read count").
						Int("want", 0).
						Int("unexpected-count", read),
				)
			}
		} else {
			testlog.Error(t, errors.New("io.EOF was expected"))
		}
	})

	t.Run("positive-3", func(t *testing.T) {
		// В этом сценарии проверяется переиспользование буфера в случае если
		// там осталось достаточно места минус подтверждённая вычитка.

		ctrl := gomock.NewController(t)
		m := extmocks.NewReaderMock(ctrl)

		r := ackio.New(
			m,
			ackio.WithFrameSize(3),
			ackio.WithReaderBufferSize(5),
			ackio.WithReaderSourcePosition(5),
		)

		first := m.EXPECT().Read(gomock.Len(5)).DoAndReturn(func(dst []byte) (int, error) {
			copy(dst, "Hello")
			return 5, nil
		})

		var tmpbuf [8]byte
		if _, err := r.Read(tmpbuf[:4]); err != nil {
			testlog.Error(t, errors.Wrap(err, "read 4 bytes"))
			return
		}
		if err := r.Ack(4); err != nil {
			testlog.Error(t, errors.Wrap(err, "acknowledge 4 bytes read"))
		}

		m.EXPECT().Read(gomock.Len(4)).DoAndReturn(func(dst []byte) (int, error) {
			copy(dst, "k")
			return 1, io.EOF
		}).After(first)
		var buf bytes.Buffer
		if _, err := io.Copy(&buf, r); err != nil {
			testlog.Error(t, errors.Wrap(err, "read the rest"))
			return
		}
		if buf.String() != "ok" {
			testlog.Error(
				t,
				errors.New("unexpected rest").Str("want", "ok").Stg("unexpected-data", &buf),
			)
			return
		}
	})

	t.Run("no read for empty dest", func(t *testing.T) {
		// Здесь читаем в пустой буфер
		r := ackio.New(nil)
		read, err := r.Read(nil)
		if err != nil {
			testlog.Error(t, errors.Wrap(err, "read into empty buffer"))
			return
		}
		if read != 0 {
			t.Error("unexpected content was read")
		}
	})

	t.Run("data may be not available yet", func(t *testing.T) {
		// В этом сценарии проверяем работу с источником который
		// не сразу имеет данные.

		ctrl := gomock.NewController(t)
		m := extmocks.NewReaderMock(ctrl)

		r := ackio.New(
			m,
			ackio.WithFrameSize(3),
			ackio.WithReaderBufferSize(5),
			ackio.WithReaderSourcePosition(5),
		)

		gomock.InOrder(
			m.EXPECT().Read(gomock.Any()).Return(0, nil),
			m.EXPECT().Read(gomock.Any()).DoAndReturn(func(dst []byte) (int, error) {
				copy(dst, "*")
				return 1, io.EOF
			}),
		)

		var buf bytes.Buffer
		if _, err := io.Copy(&buf, r); err != nil {
			testlog.Error(t, errors.Wrap(err, "copy content"))
			return
		}
		if buf.String() != "*" {
			testlog.Log(
				t,
				errors.New("unexpected content").Str("want", "*").Stg("unexpected-data", &buf),
			)
		}
	})

	t.Run("work without explicit frame", func(t *testing.T) {
		// Проверяем работу когда не задан размер кадра.

		ctrl := gomock.NewController(t)
		m := extmocks.NewReaderMock(ctrl)

		r := ackio.New(m, ackio.WithReaderBufferSize(5))

		m.EXPECT().Read(gomock.Any()).Return(0, io.EOF)

		var buf bytes.Buffer
		read, err := io.Copy(&buf, r)
		if err != nil {
			testlog.Error(t, errors.Wrap(err, "copy content"))
			return
		}
		if read != 0 {
			testlog.Error(t, errors.New("expected empty content").Stg("unexpected-content", &buf))
		}
	})

	t.Run("ack bound check", func(t *testing.T) {

		tests := []struct {
			name    string
			bound   int
			wantErr bool
		}{
			{
				name:    "negative bounds are not allowed",
				bound:   -1,
				wantErr: true,
			},
			{
				name:    "zero bound is not allowed",
				bound:   0,
				wantErr: true,
			},
			{
				name:    "bound out of range",
				bound:   5,
				wantErr: true,
			},
			{
				name:    "ok bound",
				bound:   1,
				wantErr: false,
			},
		}
		for _, tt := range tests {
			t.Run(tt.name, func(t *testing.T) {
				ctrl := gomock.NewController(t)
				m := extmocks.NewReaderMock(ctrl)
				r := ackio.New(
					m,
					ackio.WithFrameSize(3),
					ackio.WithReaderBufferSize(5),
					ackio.WithReaderSourcePosition(5),
				)

				m.EXPECT().Read(gomock.Any()).Return(2, io.EOF)
				var buf bytes.Buffer
				_, _ = io.Copy(&buf, r)

				err := r.Ack(tt.bound)
				switch {
				case tt.wantErr && err != nil:
					testlog.Log(t, errors.Wrap(err, "expected error"))
				case tt.wantErr && err == nil:
					t.Error("expected error got nothing")
				case !tt.wantErr && err != nil:
					testlog.Error(t, errors.Wrap(err, "unexpected error"))
				case !tt.wantErr && err == nil:
				}
			})
		}
	})
}

func checkBytes(p []byte, want string) error {
	if string(p) != want {
		return errors.New("unexpected slice content").
			Str("wanted", want).
			Str("invalid", string(p))
	}

	return nil
}
