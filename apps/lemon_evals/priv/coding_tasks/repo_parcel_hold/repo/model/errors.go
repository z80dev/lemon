package model

import "errors"

var ErrNotFound = errors.New("parcel not found")
var ErrAlreadyExists = errors.New("parcel already exists")
