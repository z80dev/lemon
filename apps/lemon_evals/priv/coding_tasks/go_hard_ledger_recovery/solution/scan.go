package ledger

import (
	"encoding/binary"
	"hash/crc32"
)

func Scan(data []byte) ([]Record, int, error) {
	out := []Record{}
	offset := 0
	var previous uint64
	for len(data)-offset >= 4 {
		n := int(binary.BigEndian.Uint32(data[offset:]))
		if n == 0 || n > MaxPayload {
			return out, offset, ErrCorrupt
		}
		if len(data)-offset < n+frameOverhead {
			break
		}
		payload := data[offset+4 : offset+4+n]
		checksum := binary.BigEndian.Uint32(data[offset+4+n:])
		if crc32.ChecksumIEEE(payload) != checksum {
			return out, offset, ErrCorrupt
		}
		r, err := decodeRecord(payload)
		if err != nil || r.Sequence == 0 || (len(out) > 0 && (previous == ^uint64(0) || r.Sequence != previous+1)) {
			return out, offset, ErrCorrupt
		}
		out = append(out, r)
		previous = r.Sequence
		offset += n + frameOverhead
	}
	return out, offset, nil
}
