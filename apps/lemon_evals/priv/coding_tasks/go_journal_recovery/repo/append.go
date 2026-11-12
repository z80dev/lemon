package journal

import (
	"os"
)

func AppendFile(path string, payloads [][]byte) error {
	data, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	records, _, err := Scan(data)
	if err != nil {
		return err
	}
	var sequence uint64
	if len(records) > 0 {
		sequence = records[len(records)-1].Sequence
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	for _, p := range payloads {
		sequence++
		frame, err := Encode(Record{sequence, p})
		if err != nil {
			return err
		}
		if _, err = f.Write(frame); err != nil {
			return err
		}
	}
	return nil
}
