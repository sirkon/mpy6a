package handlers

import (
	"go/types"
	"strconv"

	"github.com/sirkon/fenneg"
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

// Name для реализации fenneg.TypeHandler.
func (i *Index) Name(r *fenneg.Go) string {
	return r.Type(i.id)
}

// Pre для реализации fenneg.TypeHandler.
func (i *Index) Pre(r *fenneg.Go, src string) {}

// Len для реализации fenneg.TypeHandler.
func (i *Index) Len() int {
	return 16
}

// LenExpr для реализации fenneg.TypeHandler.
func (i *Index) LenExpr(r *fenneg.Go, src string) string {
	return strconv.Itoa(i.Len())
}

// Encoding для реализации fenneg.TypeHandler.
func (i *Index) Encoding(r *fenneg.Go, dst, src string) {
	r.L(`$dst = $0($dst, $src)`, r.PkgObject(i.id, "IndexEncodeAppend"))
}

// Decoding для реализации fenneg.TypeHandler.
func (i *Index) Decoding(r *fenneg.Go, dst, src string) bool {
	r.Imports().Errors().Ref("errors")

	r.L(`if len($src) < 16 {`)
	fenneg.ReturnError().New("$decode: $recordTooSmall").LenReq(16).LenSrc().Rend(r)
	r.L(`}`)
	r.L(`$0(&$dst, $src)`, r.PkgObject(i.id, "IndexDecode"))

	return false
}

var _ fenneg.TypeHandler = &Index{}
