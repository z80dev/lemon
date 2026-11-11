package replay

import "errors"

var (
	ErrInvalid = errors.New("invalid broker argument")
	ErrClosed  = errors.New("broker closed")
	ErrCursor  = errors.New("cursor ahead of topic")
	ErrExpired = errors.New("cursor expired")
	ErrBacklog = errors.New("replay exceeds buffer")
	ErrSlow    = errors.New("slow subscriber")
)

type Message struct {
	Sequence uint64
	Payload  []byte
}
