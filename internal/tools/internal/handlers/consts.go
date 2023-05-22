package handlers

import "github.com/sirkon/olrgen"

const (
	mpy6aTypesPkg = "github.com/sirkon/mpy6a/internal/types"
	mpy6aLogopPkg = "github.com/sirkon/mpy6a/internal/logop"
	errorsPkg     = "github.com/sirkon/mpy6a/internal/errors"
)

func init() {
	olrgen.SetStructuredErrorsPkgPath(errorsPkg)
}
