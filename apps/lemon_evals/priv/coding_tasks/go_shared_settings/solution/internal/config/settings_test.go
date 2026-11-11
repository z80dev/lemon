package config

import (
	"errors"
	"testing"
)

func TestRejectDuplicate(t *testing.T) {
	_, err := Parse("workers=2\nworkers=3")
	if !errors.Is(err, ErrInvalid) {
		t.Fatal(err)
	}
}
