package inventory

import "errors"

type Event struct {
	ID, Kind, SKU string
	Quantity      int64
	Ref           string
}
type Balance struct {
	SKU      string
	Quantity int64
}

var ErrInvalid = errors.New("invalid inventory batch")
