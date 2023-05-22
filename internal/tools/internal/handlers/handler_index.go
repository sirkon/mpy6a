package handlers

import (
	"go/types"
	"strconv"

	"github.com/sirkon/olrgen"
)

// NewIndex конструктор нового воплощения Index.
func NewIndex(id *types.Named) *Index {
	if id.Obj().Pkg().Path() != mpy6aTypesPkg {
		return nil
	}

	if id.Obj().Name() != "Index" {
		return nil
	}

	return &Index{
		id: id,
	}
}

// Index поддержка типа types.Index.
type Index struct {
	id *types.Named
}

// Name для реализации olrgen.TypeHandler.
func (i *Index) Name(r *olrgen.Go) string {
	return r.Type(i.id)
}

// Pre для реализации olrgen.TypeHandler.
func (i *Index) Pre(r *olrgen.Go, src string) {}

// Len для реализации olrgen.TypeHandler.
func (i *Index) Len() int {
	return 16
}

// LenExpr для реализации olrgen.TypeHandler.
func (i *Index) LenExpr(r *olrgen.Go, src string) string {
	return strconv.Itoa(i.Len())
}

// Encoding для реализации olrgen.TypeHandler.
func (i *Index) Encoding(r *olrgen.Go, dst, src string) {
	r.Imports().Add(mpy6aTypesPkg).Ref("mpy6aIndex")

	r.L(`$dst = $mpy6aIndex.IndexEncodeAppend($dst, $src)`)
}

// Decoding для реализации olrgen.TypeHandler.
func (i *Index) Decoding(r *olrgen.Go, dst, src string) bool {
	r.Imports().Errors().Ref("errors")
	r.Imports().Add(mpy6aTypesPkg).Ref("mpy6aIndex")

	r.L(`if len($src) < 16 {`)
	olrgen.ReturnError().New("$decode: $recordTooSmall").LenReq(16).LenSrc().Rend(r)
	r.L(`}`)
	r.L(`$dst = $mpy6aIndex.IndexDecode($src)`)

	return false
}

var _ olrgen.TypeHandler = &Index{}
