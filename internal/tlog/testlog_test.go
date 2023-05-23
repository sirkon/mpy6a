package tlog_test

import (
	stderrs "errors"
	"testing"

	"github.com/sirkon/mpy6a/internal/errors"
	"github.com/sirkon/mpy6a/internal/tlog"
)

func TestLogging(t *testing.T) {
	t.Run("log-std-error", func(t *testing.T) {
		tlog.Log(t, stderrs.New("not an error"))
	})

	t.Run("log-ctxed-error", func(t *testing.T) {
		tlog.Log(t, errors.New("ctx error").Int("int", 12).Any("map", map[string]string{
			"a": "b",
		}).Str("string", "str"))
	})

	t.Run("error", func(t *testing.T) {
		tlog.Error(t, errors.New("error").Bool("is-error", true))
	})
}
