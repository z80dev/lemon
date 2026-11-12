package releasegraph

import "errors"

var ErrInvalid = errors.New("invalid release graph")
var ErrConflict = errors.New("revision conflict")

type ValidationError struct {
	Code  string
	Names []string
}

func (e *ValidationError) Error() string { return e.Code }
func (e *ValidationError) Unwrap() error { return ErrInvalid }
