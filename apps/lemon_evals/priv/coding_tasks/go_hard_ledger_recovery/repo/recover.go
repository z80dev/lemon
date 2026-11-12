package ledger

func Recover(initial Snapshot, data []byte) (Result, error) {
	records, offset, err := Scan(data)
	if err != nil {
		return Result{}, err
	}
	result, err := Replay(initial, records)
	if err != nil {
		return Result{}, err
	}
	result.ValidBytes = offset
	return result, nil
}
