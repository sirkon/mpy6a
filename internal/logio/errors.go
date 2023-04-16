package logio

import "fmt"

type errorEventTooLarge struct {
	evlim int
	rec   []byte
}

func (e errorEventTooLarge) Error() string {
	return fmt.Sprintf("the event length %d is out of the limit of %d bytes", len(e.rec), e.evlim)
}

// ErrorLogIntegrityCompromised возвращается, если в логе найдена какая-то ерунда
// противоречащая предположениям об его устройстве.
type ErrorLogIntegrityCompromised struct{}

func (e ErrorLogIntegrityCompromised) Error() string {
	return "log integrity compromised"
}
