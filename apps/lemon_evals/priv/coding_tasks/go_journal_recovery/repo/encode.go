package journal

import (
	"encoding/binary"
	"fmt"
	"hash/crc32"
)

func Encode(record Record) ([]byte, error) {
	if record.Sequence == 0 || len(record.Payload) > MaxPayload {
		return nil, fmt.Errorf("%w", ErrInvalid)
	}
	out := make([]byte, 16+len(record.Payload))
	binary.BigEndian.PutUint32(out[:4], uint32(len(record.Payload)))
	binary.BigEndian.PutUint64(out[4:12], record.Sequence)
	copy(out[12:], record.Payload)
	binary.BigEndian.PutUint32(out[len(out)-4:], crc32.ChecksumIEEE(out[4:len(out)-4]))
	return out, nil
}
