package journal

import (
	"errors"
	"fmt"
)

const MaxPayload = 1 << 20

var ErrInvalid = errors.New("invalid journal record")

type Record struct {
	Sequence uint64
	Payload  []byte
}
type CorruptionError struct {
	Offset int
	Reason string
}

func (e *CorruptionError) Error() string {
	return fmt.Sprintf("journal corruption at %d: %s", e.Offset, e.Reason)
}
