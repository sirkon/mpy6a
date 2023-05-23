package main

import (
	"go/types"
	"os"

	"github.com/sirkon/errors"
	"github.com/sirkon/fenneg"
	"github.com/sirkon/message"
	"github.com/sirkon/mpy6a/internal/tools/internal/handlers"
)

func main() {
	const appName = "test"

	if err := os.Chdir("../.."); err != nil {
		message.Critical(errors.Wrap(err, "chdir somewhere into mpy6a main module area"))
	}

	hnlrs, err := fenneg.NewTypesHandlers(
		// Add custom handler for the example.Index type
		fenneg.NewTypeHandler(
			// Поддержка типа Index.
			func(ot types.Type) fenneg.TypeHandler {
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
		fenneg.NewTypeHandler(
			func(ot types.Type) fenneg.TypeHandler {
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

	const (
		mpy6aErrs = "github.com/sirkon/mpy6a/internal/errors"
		logopPkg  = "github.com/sirkon/mpy6a/internal/logop"
	)

	r, err := fenneg.NewRunner(mpy6aErrs, hnlrs)
	if err != nil {
		message.Critical(errors.Wrap(err, "set up codegen runner"))
	}

	olr := r.OpLog().
		Source(logopPkg, "Logop").
		Type(logopPkg, "Recorder")
	if err := olr.Run(); err != nil {
		message.Critical(errors.Wrap(err, "run Logop/Recorder codegen"))
	}

	if err := r.Struct("github.com/sirkon/mpy6a/internal/types", "Session"); err != nil {
		message.Critical(errors.Wrap(err, "run Session codegen"))
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
