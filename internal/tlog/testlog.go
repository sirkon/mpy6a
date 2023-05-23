package tlog

import (
	"fmt"
	"strings"

	"github.com/sirkon/mpy6a/internal/errors"
)

const (
	bold = "\033[1m"
	red  = "\033[1;31m"
)

// Log logs error.
func Log(t TestingPrinter, err error) {
	t.Helper()
	t.Log(renderString(err, bold))
}

// Error signal error.
func Error(t TestingPrinter, err error) {
	t.Helper()
	t.Error(renderString(err, red))
}

// Check do nothing and return false if error is nil.
// Prints error and return true otherwise.
func Check(t TestingPrinter, err error) bool {
	if err == nil {
		return false
	}

	t.Helper()
	t.Error(renderString(err, red))
	return true
}

func renderString(err error, highlight string) string {
	if err == nil {
		return "<nil>"
	}

	var b strings.Builder
	b.WriteString(highlight)
	b.WriteString(err.Error())
	b.WriteString("\033[0m\n")

	d := errors.GetContextDeliverer(err)
	if d == nil {
		return b.String()
	}

	var c errorContextConsumer
	d.Deliver(&c)

	if len(c.vars) == 0 {
		return b.String()
	}

	var maxname int
	for _, v := range c.vars {
		if len(v.name) > maxname {
			maxname = len(v.name)
		}
	}

	for _, v := range c.vars {
		b.WriteString("    \033[1m")
		b.WriteString(v.name)
		b.WriteString("\033[0m")
		b.WriteString(`: `)
		b.WriteString(strings.Repeat(" ", maxname-len(v.name)))
		_, _ = fmt.Fprintln(&b, v.value)
	}
	return b.String()
}
