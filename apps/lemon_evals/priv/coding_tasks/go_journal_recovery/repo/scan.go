package journal

import (
	"encoding/binary"
	"fmt"
)

func Scan(data []byte) ([]Record, int, error) {
	var records []Record
	offset := 0
	for offset < len(data) {
		if len(data)-offset < 16 {
			return records, offset, fmt.Errorf("short frame")
		}
		n := int(binary.BigEndian.Uint32(data[offset:]))
		end := offset + 16 + n
		if end > len(data) {
			return records, offset, fmt.Errorf("short body")
		}
		records = append(records, Record{binary.BigEndian.Uint64(data[offset+4:]), data[offset+12 : end-4]})
		offset = end
	}
	return records, offset, nil
}
