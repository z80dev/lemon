package retention

import "errors"

type Snapshot struct {
	ID, Volume string
	Created    int64
	Pinned     bool
}
type Policy struct {
	Keep   int
	Cutoff int64
}

var ErrInvalid = errors.New("invalid retention input")
