package journal

import (
	"errors"
	"fmt"
	"math"
	"os"
)

func AppendFile(path string, payloads [][]byte) error {
	data, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	records, valid, err := Scan(data)
	if err != nil {
		return err
	}
	var seq uint64
	if len(records) > 0 {
		seq = records[len(records)-1].Sequence
	}
	if uint64(len(payloads)) > math.MaxUint64-seq {
		return fmt.Errorf("%w: sequence exhausted", ErrInvalid)
	}
	for _, p := range payloads {
		if len(p) > MaxPayload {
			return fmt.Errorf("%w: payload too large", ErrInvalid)
		}
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	if err = f.Truncate(int64(valid)); err != nil {
		return err
	}
	if _, err = f.Seek(int64(valid), 0); err != nil {
		return err
	}
	for _, p := range payloads {
		seq++
		frame, _ := Encode(Record{seq, p})
		if _, err = f.Write(frame); err != nil {
			return err
		}
	}
	return f.Close()
}
