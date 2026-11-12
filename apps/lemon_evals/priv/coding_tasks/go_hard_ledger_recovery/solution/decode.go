package ledger

import (
	"bytes"
	"encoding/json"
	"io"
)

func decodeRecord(payload []byte) (Record, error) {
	var r Record
	d := json.NewDecoder(bytes.NewReader(payload))
	d.DisallowUnknownFields()
	if err := d.Decode(&r); err != nil {
		return Record{}, err
	}
	var extra any
	if err := d.Decode(&extra); err != io.EOF {
		return Record{}, ErrCorrupt
	}
	return r, nil
}
