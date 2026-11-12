package ledger

import "sort"

func Replay(initial Snapshot, records []Record) (Result, error) {
	initial, err := ValidateSnapshot(initial)
	if err != nil {
		return Result{}, err
	}
	w := newWorking(initial)
	out := Result{Committed: []string{}, Replayed: []string{}, Discarded: []string{}}
	sequence := initial.Sequence
	for _, r := range records {
		if err = validateRecord(r); err != nil {
			return Result{}, err
		}
		sequence = r.Sequence
		switch r.Kind {
		case "begin":
			w.pending[r.Tx] = []Record{}
		case "open", "post", "close":
			w.pending[r.Tx] = append(w.pending[r.Tx], r)
		case "abort":
			delete(w.pending, r.Tx)
		case "commit":
			_, err = w.commit(r.Tx, r.Sequence)
			if err != nil {
				return Result{}, err
			}
			out.Committed = append(out.Committed, r.Tx)
		}
	}
	for tx := range w.pending {
		out.Discarded = append(out.Discarded, tx)
	}
	sort.Strings(out.Discarded)
	out.State = w.snapshot(sequence)
	return out, nil
}
