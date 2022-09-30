package logio

import "fmt"

type errorEventTooLarge struct {
	limit int
	rec   []byte
}

func (e errorEventTooLarge) Error() string {
	return fmt.Sprintf("the event length %d is out of limit of %d bytes", len(e.rec), e.limit)
}
