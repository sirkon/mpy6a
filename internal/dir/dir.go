package dir

import (
	"os"
	"path/filepath"

	"github.com/sirkon/mpy6a/internal/errors"
)

// New создание новой директории.
func New(p, sprefix string) (res *Dir, err error) {
	res = &Dir{
		path: p,
	}

	stat, err := os.Stat(p)
	if err == nil {
		if !stat.IsDir() {
			return nil, errors.Newf("'%s' exists and it is not a directory", p)
		}

		return res, nil
	}

	if !os.IsNotExist(err) {
		return nil, errors.Wrap(err, "check path")
	}

	if err := os.MkdirAll(p, 0755); err != nil {
		return nil, errors.Wrap(err, "create directory")
	}

	return res, nil
}

// Dir представление директории.
type Dir struct {
	path string
}

// List получение имён файлов в директории удовлетворяющих шаблону.
// Директории исключаются.
func (d *Dir) List(pattern string) ([]string, error) {
	files, err := os.ReadDir(d.path)
	if err != nil {
		return nil, errors.Wrapf(err, "read directory '%s'", d.path)
	}

	var res []string
	for _, file := range files {
		if file.IsDir() {
			continue
		}

		ok, err := filepath.Match(pattern, file.Name())
		if err != nil {
			return nil, errors.Wrapf(err, "match file '%s' against the pattern", file.Name())
		}

		if !ok {
			continue
		}

		res = append(res, file.Name())
	}

	return res, nil
}

// Create создание в директории нового файла.
func (d *Dir) Create(name string) (*os.File, error) {
	res, err := os.Create(filepath.Join(d.path, name))
	if err != nil {
		return nil, err
	}

	return res, nil
}

// Open открытие файла из директории на чтение.
func (d *Dir) Open(name string) (*os.File, error) {
	res, err := os.Open(filepath.Join(d.path, name))
	if err != nil {
		return nil, err
	}

	return res, nil
}
