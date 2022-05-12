//go:build integration

package state

import (
	"io"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/sirkon/errors"
)

func TestSequenceFile(t *testing.T) {
	t.Run("not-concurrent-write-read", func(t *testing.T) {
		// Сценарий теста:
		// 1. Создаём новый файл.
		// 2. Заполняем его сессиями.
		// 3. Закрываем файл на запись.
		// 4. Читаем сессии и проверяем, что всё нормально сохранилось.

		w, fname, err := createWriteFile(t)
		if err != nil {
			t.Error(errors.Wrap(err, "create write file"))
			return
		}

		r, err := os.Open(fname)
		if err != nil {
			t.Error(errors.Wrap(err, "create file reader"))
			return
		}

		f, err := NewSequenceFile(w, r, 0, 0, 100)
		if err != nil {
			t.Error(errors.Wrap(err, "init sequence file"))
			return
		}
		defer func() {
			if err := f.CloseRead(); err != nil {
				t.Error(errors.Wrap(err, "close read file"))
			}
		}()

		const sessionsCount = 1000
		for i := 0; i < sessionsCount; i++ {
			if err := f.WriteSession([]byte(strconv.Itoa(i))); err != nil {
				t.Error(errors.Wrapf(err, "write session no %d", i))
				return
			}
		}

		if err := f.CloseWrite(); err != nil {
			t.Error(errors.Wrap(err, "close write"))
			return
		}

		var count int
		for {
			session, err := f.ReadSession()
			if err != nil {
				if err == io.EOF {
					break
				}

				t.Error(errors.Wrapf(err, "read session count %d", count))
				return
			}

			expected := strconv.Itoa(count)
			got := string(session)
			if expected != got {
				t.Errorf(
					"expected session content '%s' for session no %d, got '%s'",
					expected,
					count,
					got,
				)
				return
			}
			count++
		}

		if count != sessionsCount {
			t.Errorf("expected count %d, got %d", sessionsCount, count)
			return
		}
	})

	t.Run("read-completed-file", func(t *testing.T) {
		// 1. Создаём файл новый файл.
		// 2. Заполняем его сессиями.
		// 3. Закрываем файл на запись.
		// 4. Открываем новый SequenceFile для чтения.
		// 5. Читаем до конца, проверяя содержимое записанных сессий.

		// Сценарий теста:
		// 1. Создаём новый файл.
		// 2. Заполняем его сессиями.
		// 3. Закрываем файл на запись.
		// 4. Читаем сессии и проверяем, что всё нормально сохранилось.

		w, fname, err := createWriteFile(t)
		if err != nil {
			t.Error(errors.Wrap(err, "create write file"))
			return
		}

		r, err := os.Open(fname)
		if err != nil {
			t.Error(errors.Wrap(err, "create file reader"))
			return
		}

		f, err := NewSequenceFile(w, r, 0, 0, 100)
		if err != nil {
			t.Error(errors.Wrap(err, "init sequence file"))
			return
		}

		const sessionsCount = 1000
		for i := 0; i < sessionsCount; i++ {
			if err := f.WriteSession([]byte(strconv.Itoa(i))); err != nil {
				t.Error(errors.Wrapf(err, "write session no %d", i))
				return
			}
		}

		if err := f.CloseWrite(); err != nil {
			t.Error(errors.Wrap(err, "close write"))
			return
		}

		f, err = NewSequenceFile(nil, r, f.wsize, 0, 100)
		if err != nil {
			t.Error(errors.Wrap(err, "init new sequence file"))
		}

		var count int
		for {
			session, err := f.ReadSession()
			if err != nil {
				if err == io.EOF {
					break
				}

				t.Error(errors.Wrapf(err, "read session count %d", count))
				return
			}

			expected := strconv.Itoa(count)
			got := string(session)
			if expected != got {
				t.Errorf(
					"expected session content '%s' for session no %d, got '%s'",
					expected,
					count,
					got,
				)
				return
			}
			count++
		}

		if count != sessionsCount {
			t.Errorf("expected count %d, got %d", sessionsCount, count)
			return
		}
	})

	t.Run("concurrent-read", func(t *testing.T) {
		// Сценарий теста:
		// 1. Создаём новый файл.
		// 2. Осуществляем конкурентную вычитку (начинается ДО записи) и запись.
		// 3. После записи данных закрываем файл на запись.
		// 4. Дожидаемся завершения потока чтения, которое должно произойти при получении io.EOF

		w, fname, err := createWriteFile(t)
		if err != nil {
			t.Error(errors.Wrap(err, "create write file"))
			return
		}

		r, err := os.Open(fname)
		if err != nil {
			t.Error(errors.Wrap(err, "create file reader"))
			return
		}

		f, err := NewSequenceFile(w, r, 0, 0, 4)
		if err != nil {
			t.Error(errors.Wrap(err, "init sequence file"))
			return
		}

		var wg sync.WaitGroup

		// Запускаем вычитку вплоть до io.EOF
		wg.Add(1)
		readerStarted := make(chan struct{})
		const sessionsCount = 1000

		go func() {
			var readCount int

			defer func() {
				if err := f.CloseRead(); err != nil {
					t.Error(errors.Wrap(err, "close read"))
				}
				if readCount != sessionsCount {
					t.Errorf("%d sessions were expected to be counted, got %d", sessionsCount, readCount)
				}
				wg.Done()
			}()
			go func() {
				close(readerStarted)
			}()

			for {
				session, err := f.ReadSession()
				if err != nil {
					if err == io.EOF {
						return
					}

					t.Error(errors.Wrapf(err, "read session at step %d", readCount))
					return
				}

				if len(session) == 0 {
					time.Sleep(time.Second / 100)
					continue
				}

				s := string(session)
				if s != strconv.Itoa(readCount) {
					t.Errorf("unexpected session detected: '%d' data expected, got '%s'", readCount, s)
					return
				}

				// t.Logf("got new session: '%d'", readCount)
				readCount++
			}
		}()

		// дожидаемся начала работы читалки, чтобы она могла начать читать прежде чем мы начнём писать
		<-readerStarted

		// чтобы ещё немножко отсрочить запись запускаем её в горутине
		wg.Add(1)
		go func() {
			defer wg.Done()

			for i := 0; i < sessionsCount; i++ {
				if err := f.WriteSession([]byte(strconv.Itoa(i))); err != nil {
					t.Error(errors.Wrap(err, "write new session"))
					return
				}

				time.Sleep(time.Second / 10000)
			}

			if err := f.CloseWrite(); err != nil {
				t.Error(errors.Wrap(err, "close write"))
			}
		}()

		wg.Wait()
	})
}

func createWriteFile(t *testing.T) (w *os.File, fname string, err error) {
	w, err = os.CreateTemp("testdata", "sequence")
	if err != nil {
		return nil, "", err
	}

	_, base := filepath.Split(w.Name())
	fname = filepath.Join("testdata", base)
	t.Cleanup(func() {
		if err := os.Remove(fname); err != nil {
			t.Error(errors.Wrap(err, "remove temporary file"))
		}
	})

	return w, fname, err
}

func sessionData(i int) []byte {
	return []byte(strconv.Itoa(i))
}
