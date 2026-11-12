package ledger

import "errors"

var ErrInvalid = errors.New("invalid ledger")
var ErrCorrupt = errors.New("corrupt journal")
var ErrConflict = errors.New("sequence conflict")
