package handlers

import (
	"go/types"

	"github.com/sirkon/olrgen"
)

// NewOptionalRepeat конструктор нового воплощения OptionalRepeat.
func NewOptionalRepeat(r *types.Named) *OptionalRepeat {
	if r.Obj().Pkg().Path() != mpy6aLogopPkg {
		return nil
	}

	if r.Obj().Name() != "OptionalRepeat" {
		return nil
	}

	return &OptionalRepeat{
		r: r,
	}
}

// OptionalRepeat поддержка типа logops.OptionalRepeat.
type OptionalRepeat struct {
	r      *types.Named
	lenkey string
}

// Name для реализации olrgen.TypeHandler.
func (o *OptionalRepeat) Name(r *olrgen.Go) string {
	return r.Type(o.r)
}

// Pre для реализации olrgen.TypeHandler.
func (o *OptionalRepeat) Pre(r *olrgen.Go, src string) {
	r.Imports().Varsize().Ref("$vars")

	o.lenkey = r.Uniq("key", src)
	r.L(`var $0 int`, o.lenkey)
	r.L(`if $src != 0 {`)
	r.L(`    $0 = $vars.Uint($src)`, o.lenkey)
	r.L(`}`)
}

// Len для реализации olrgen.TypeHandler.
func (o *OptionalRepeat) Len() int {
	return -1
}

// LenExpr для реализации olrgen.TypeHandler.
func (o *OptionalRepeat) LenExpr(r *olrgen.Go, src string) string {
	return o.lenkey
}

// Encoding для реализации olrgen.TypeHandler.
func (o *OptionalRepeat) Encoding(r *olrgen.Go, dst, src string) {
	r.Imports().Binary().Ref("bin")

	r.L(`if $src != 0 {`)
	r.L(`    $dst = $bin.AppendUvarint($dst, uint64($src))`)
	r.L(`}`)
}

// Decoding для реализации olrgen.TypeHandler.
func (o *OptionalRepeat) Decoding(r *olrgen.Go, dst, src string) bool {
	r.Imports().Binary().Ref("bin")
	r.Imports().Errors().Ref("errors")

	off := r.Uniq("off")
	siz := r.Uniq("size")
	r.Let("siz", siz)
	r.Let("off", off)

	r.L(`if len($src) > 0 {`)
	r.L(`    $siz, $off := $bin.Uvarint($src)`)
	r.L(`    if $off <= 0 {`)
	r.L(`        if $off == 0 {`)
	olrgen.ReturnError().New("$decode: $recordTooSmall").Rend(r)
	r.L(`        }`)
	olrgen.ReturnError().New("$decode - optional repeat timeout: $malformedUvarint").Rend(r)
	r.L(`    }`)
	r.N()
	r.L(`    $dst = $0($siz)`, r.Type(o.r))
	r.L(`    $src = $src[off:]`)
	r.L(`}`)

	return true
}
