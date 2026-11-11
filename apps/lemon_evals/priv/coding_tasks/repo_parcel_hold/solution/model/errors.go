package model

import "errors"

var ErrNotFound = errors.New("parcel not found")
var ErrAlreadyExists = errors.New("parcel already exists")

var ErrInvalidReason = errors.New("reason must contain 1 to 120 characters")
var ErrDelivered = errors.New("delivered parcel cannot be held")
var ErrAlreadyHeld = errors.New("parcel already held")
