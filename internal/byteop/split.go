package byteop

import (
	"strconv"
	"strings"

	"github.com/sirkon/mpy6a/internal/errors"
)

// Split разделить источник байтов на два с данным индексом раздела n,
// причём первый слайс будет содержать первые n байтов источника,
// а второй — оставшиеся.
func Split(src []byte, n int) (head []byte, tail []byte, err error) {
	switch {
	case n < 0:
		return nil, nil, errors.Const("cannot split with negative index")
	case n < len(src):
		return src[:n], src[n:], nil
	default:
		var msg strings.Builder
		msg.WriteString("cannot split when the index ")
		msg.WriteString(strconv.Itoa(n))
		msg.WriteString(" larger than the slice length ")
		msg.WriteString(strconv.Itoa(len(src)))
		return nil, nil, errors.Const(msg.String())
	}
}
