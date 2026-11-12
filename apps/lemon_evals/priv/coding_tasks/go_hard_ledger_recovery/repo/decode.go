package ledger

import "encoding/json"

func decodeRecord(payload []byte) (Record, error) {
	var r Record
	err := json.Unmarshal(payload, &r)
	return r, err
}
