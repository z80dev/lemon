package ledger

import (
	"encoding/binary"
	"encoding/json"
	"hash/crc32"
)

func Encode(r Record) ([]byte, error) {
	if r.Sequence == 0 {
		return nil, ErrInvalid
	}
	data, err := json.Marshal(r)
	if err != nil || len(data) > MaxPayload {
		return nil, ErrInvalid
	}
	out := make([]byte, len(data)+frameOverhead)
	binary.BigEndian.PutUint32(out, uint32(len(data)))
	copy(out[4:], data)
	binary.BigEndian.PutUint32(out[len(out)-4:], crc32.ChecksumIEEE(data))
	return out, nil
}
