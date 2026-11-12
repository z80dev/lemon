package jsonapi

import (
	"encoding/json"
	"fmt"
	"io"
)

func decode(r io.Reader, v any) error {
	d := json.NewDecoder(r)
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		return err
	}
	var extra any
	if err := d.Decode(&extra); err != io.EOF {
		if err != nil {
			return err
		}
		return fmt.Errorf("trailing JSON value")
	}
	return nil
}
func encode(w io.Writer, v any) error { return json.NewEncoder(w).Encode(v) }
