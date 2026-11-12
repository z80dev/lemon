package ledger

func Recover(initial Snapshot, data []byte) (Result, error) {
	initial, err := ValidateSnapshot(initial)
	if err != nil {
		return Result{}, err
	}
	records, offset, err := Scan(data)
	if err != nil {
		return Result{}, err
	}
	result, err := replayValidated(initial, records)
	if err != nil {
		return Result{}, err
	}
	result.ValidBytes = offset
	return result, nil
}
