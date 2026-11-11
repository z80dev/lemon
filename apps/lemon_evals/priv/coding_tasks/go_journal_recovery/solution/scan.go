package journal

import (
	"encoding/binary"
	"hash/crc32"
)

func Scan(data []byte) ([]Record, int, error) {
	var out []Record
	offset := 0
	var last uint64
	for offset < len(data) {
		remaining := data[offset:]
		if len(remaining) < 4 {
			return out, offset, nil
		}
		size := uint64(binary.BigEndian.Uint32(remaining[:4]))
		if size > MaxPayload {
			return out, offset, &CorruptionError{offset, "oversized payload"}
		}
		total := int(size) + 16
		if len(remaining) < total {
			return out, offset, nil
		}
		frame := remaining[:total]
		seq := binary.BigEndian.Uint64(frame[4:12])
		if crc32.ChecksumIEEE(frame[4:total-4]) != binary.BigEndian.Uint32(frame[total-4:]) {
			return out, offset, &CorruptionError{offset, "checksum mismatch"}
		}
		if seq == 0 || seq <= last {
			return out, offset, &CorruptionError{offset, "non-increasing sequence"}
		}
		payload := make([]byte, int(size))
		copy(payload, frame[12:total-4])
		out = append(out, Record{seq, payload})
		last = seq
		offset += total
	}
	return out, offset, nil
}
