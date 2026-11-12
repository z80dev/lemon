package files

import (
	l "arena/ledger"
	"arena/ledger/adapters/jsonapi"
	"os"
)

func ReadSnapshot(path string) (l.Snapshot, error) {
	f, err := os.Open(path)
	if err != nil {
		return l.Snapshot{}, err
	}
	defer f.Close()
	return jsonapi.ReadSnapshot(f)
}
func Recover(snapshotPath, journalPath string) (l.Result, error) {
	s, err := ReadSnapshot(snapshotPath)
	if err != nil {
		return l.Result{}, err
	}
	data, err := os.ReadFile(journalPath)
	if err != nil {
		return l.Result{}, err
	}
	return l.Recover(s, data)
}
