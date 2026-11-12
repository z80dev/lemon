package ledger

func EncodeRecords(records []Record) ([]byte, error) {
	out := []byte{}
	for _, r := range records {
		data, err := Encode(r)
		if err != nil {
			return nil, err
		}
		out = append(out, data...)
	}
	return out, nil
}
