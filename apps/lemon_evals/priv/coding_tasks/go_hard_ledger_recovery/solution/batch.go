package ledger

func EncodeRecords(records []Record) ([]byte, error) {
	out := []byte{}
	var previous uint64
	for i, r := range records {
		if i > 0 && (previous == ^uint64(0) || r.Sequence != previous+1) {
			return nil, ErrInvalid
		}
		data, err := Encode(r)
		if err != nil {
			return nil, err
		}
		out = append(out, data...)
		previous = r.Sequence
	}
	return out, nil
}
