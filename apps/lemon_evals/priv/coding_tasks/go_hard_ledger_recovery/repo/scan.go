package ledger

import "encoding/binary"

func Scan(data []byte) ([]Record, int, error) {
	out := []Record{}
	offset := 0
	for len(data)-offset >= 4 {
		n := int(binary.BigEndian.Uint32(data[offset:]))
		if n == 0 || n > MaxPayload {
			return out, offset, ErrCorrupt
		}
		if len(data)-offset < n+frameOverhead {
			break
		}
		r, err := decodeRecord(data[offset+4 : offset+4+n])
		if err != nil {
			return out, offset, ErrCorrupt
		}
		out = append(out, r)
		offset += n + frameOverhead
	}
	return out, offset, nil
}
