package mpio

import (
	"errors"
	"io"
	"testing"
)

func TestTryReadFull(t *testing.T) {
	tests := []struct {
		name     string
		reads    []mockReaderCall
		buflen   int
		wantN    int
		wantBuf  string
		wantErr  bool
		checkErr error
	}{
		{
			name: "empty first read",
			reads: []mockReaderCall{
				{
					data: "",
					err:  nil,
				},
			},
			buflen:  8,
			wantN:   0,
			wantBuf: "",
			wantErr: false,
		},
		{
			name: "success first attempt read",
			reads: []mockReaderCall{
				{
					data: "1234",
					err:  nil,
				},
			},
			buflen:  4,
			wantN:   4,
			wantBuf: "1234",
			wantErr: false,
		},
		{
			name: "success multiple reads",
			reads: []mockReaderCall{
				{
					data: "1234",
					err:  nil,
				},
				{
					data: "567",
					err:  nil,
				},
			},
			buflen:  7,
			wantN:   7,
			wantBuf: "1234567",
			wantErr: false,
		},
		{
			name: "numerous reads ended with io.EOF",
			reads: []mockReaderCall{
				{
					data: "1",
					err:  nil,
				},
				{
					data: "2",
					err:  nil,
				},
				{
					data: "3",
					err:  io.EOF,
				},
			},
			buflen:   3,
			wantN:    3,
			wantBuf:  "123",
			wantErr:  false,
			checkErr: nil,
		},
		{
			name: "first read is empty",
			reads: []mockReaderCall{
				{
					data: "",
					err:  nil,
				},
			},
			buflen:  8,
			wantN:   0,
			wantBuf: "",
			wantErr: false,
		},
		{
			name: "first read is io.EOF",
			reads: []mockReaderCall{
				{
					data: "",
					err:  io.EOF,
				},
			},
			buflen:   8,
			wantN:    0,
			wantBuf:  "",
			wantErr:  true,
			checkErr: io.EOF,
		},
		{
			name: "empty read when data was expected",
			reads: []mockReaderCall{
				{
					data: "123",
					err:  nil,
				},
				{
					data: "",
					err:  nil,
				},
			},
			buflen:   8,
			wantN:    0,
			wantBuf:  "",
			wantErr:  true,
			checkErr: ErrUnexpectedEOD,
		},
		{
			name: "first read is incomplete and error then",
			reads: []mockReaderCall{
				{
					data: "123",
					err:  nil,
				},
			},
			buflen:   4,
			wantN:    0,
			wantBuf:  "",
			wantErr:  true,
			checkErr: io.ErrUnexpectedEOF,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.checkErr != nil {
				tt.wantErr = true
			}

			buf := make([]byte, tt.buflen)
			gotN, err := TryReadFull(&mockReader{reads: tt.reads}, buf)
			switch {
			case err != nil && tt.wantErr:
				if tt.checkErr != nil && err != tt.checkErr {
					t.Errorf("TryReadFull() error = %s, want %s", err, tt.checkErr)
					return
				}
				t.Logf("TryReadFull() got expected error '%s'", err)
			case err != nil && !tt.wantErr:
				t.Errorf("TryReadFull() unexpected error %s", err)
			case err == nil && tt.wantErr:
				t.Errorf("TryReadFull() error was expected, got %d", gotN)
			case err == nil && !tt.wantErr:
				if gotN != tt.wantN {
					t.Errorf("TryReadFull() n %d, want %d", gotN, tt.wantN)
					return
				}

				gotbuf := string(buf[:gotN])
				if gotbuf != tt.wantBuf {
					t.Errorf("TryReadFull() buffer '%s', want '%s'", gotbuf, tt.wantBuf)
					return
				}
			}
		})
	}
}

func isEOF(err error) bool {
	return err == io.EOF
}

type mockReaderCall struct {
	data string
	err  error
}

type mockReader struct {
	reads []mockReaderCall
}

func (m *mockReader) Read(p []byte) (n int, err error) {
	if len(m.reads) == 0 {
		return 0, io.EOF
	}

	x := m.reads[0]
	m.reads = m.reads[1:]

	if len(p) < len(x.data) {
		return 0, errors.New("buffer is too small")
	}

	copy(p, x.data)
	return len(x.data), x.err
}
