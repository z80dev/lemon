package jsonapi

import (
	"encoding/json"
	"io"
)

func decode(r io.Reader, v any) error { return json.NewDecoder(r).Decode(v) }
func encode(w io.Writer, v any) error { return json.NewEncoder(w).Encode(v) }
