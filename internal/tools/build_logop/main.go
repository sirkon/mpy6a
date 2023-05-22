package main

import (
	"go/types"
	"os"

	"github.com/sirkon/errors"
	"github.com/sirkon/message"
	"github.com/sirkon/mpy6a/internal/tools/internal/handlers"
	"github.com/sirkon/olrgen"
)

func main() {
	const appName = "test"

	if err := os.Chdir("../.."); err != nil {
		message.Critical(errors.Wrap(err, "chdir somewhere into mpy6a main module area"))
	}

	// Устанавливаем всё на поддержку
	os.Args = []string{
		appName,
		"-l",
		"github.com/sirkon/mpy6a/internal/logop:Logop",
		"github.com/sirkon/mpy6a/internal/logop:Recorder",
	}

	hnlrs, err := olrgen.NewTypesHandlers(
		// Add custom handler for the example.Index type
		olrgen.NewTypeHandler(
			// Поддержка типа Index.
			func(ot types.Type) olrgen.TypeHandler {
				n := digToNamed(ot)
				if n == nil {
					return nil
				}

				h := handlers.NewIndex(n)
				if h == nil {
					return nil
				}

				return h
			},
		),
		// Поддержка типа OptionalRepeat.
		olrgen.NewTypeHandler(
			func(ot types.Type) olrgen.TypeHandler {
				n := digToNamed(ot)
				if n == nil {
					return nil
				}

				h := handlers.NewOptionalRepeat(n)
				if h == nil {
					return nil
				}

				return h
			},
		),
	)
	if err != nil {
		message.Critical(errors.Wrap(err, "set up type handlers"))
	}

	if err := olrgen.Run(appName, hnlrs); err != nil {
		message.Critical(errors.Wrap(err, "run utility"))
	}
}

func digToNamed(ot types.Type) *types.Named {
	var t *types.Named

	if v, ok := ot.(*types.Pointer); ok {
		ot = v.Elem()
	}

	t, ok := ot.(*types.Named)
	if !ok {
		return nil
	}

	return t
}
