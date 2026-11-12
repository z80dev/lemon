package routes

import "errors"

var ErrInvalid = errors.New("invalid route")

type Rule struct {
	Prefix, NextHop string
	Priority        int
}
