package jsonapi

import (
	l "arena/ledger"
	"io"
)

func ReadSnapshot(r io.Reader) (l.Snapshot, error) {
	var s l.Snapshot
	if err := decode(r, &s); err != nil {
		return l.Snapshot{}, err
	}
	return l.ValidateSnapshot(s)
}
func ReadRecords(r io.Reader) ([]l.Record, error) {
	var records []l.Record
	err := decode(r, &records)
	return records, err
}
func ReadRecovery(r io.Reader) (l.RecoveryRequest, error) {
	var req l.RecoveryRequest
	err := decode(r, &req)
	return req, err
}
func WriteSnapshot(w io.Writer, s l.Snapshot) error { return encode(w, s) }
func WriteResult(w io.Writer, r l.Result) error     { return encode(w, r) }
func WriteSummary(w io.Writer, r l.Report) error    { return encode(w, r) }
