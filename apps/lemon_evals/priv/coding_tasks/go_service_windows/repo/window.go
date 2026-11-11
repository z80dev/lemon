package windows

import "errors"

// Window is a half-open maintenance interval.
type Window struct{ Start, End int64 }

var ErrInvalid = errors.New("invalid maintenance window")
