package ledger

import "sort"

func Replay(initial Snapshot, records []Record) (Result, error) {
	initial, err := ValidateSnapshot(initial)
	if err != nil {
		return Result{}, err
	}
	return replayValidated(initial, records)
}
func replayValidated(initial Snapshot, records []Record) (Result, error) {
	w := newWorking(initial)
	out := Result{Committed: []string{}, Replayed: []string{}, Discarded: []string{}}
	sequence := initial.Sequence
	for _, r := range records {
		if sequence == ^uint64(0) || r.Sequence != sequence+1 {
			return Result{}, ErrCorrupt
		}
		if err := validateRecord(r); err != nil {
			return Result{}, err
		}
		sequence = r.Sequence
		_, active := w.pending[r.Tx]
		switch r.Kind {
		case "begin":
			if active {
				return Result{}, ErrCorrupt
			}
			w.pending[r.Tx] = []Record{}
		case "open", "post", "close":
			if !active {
				return Result{}, ErrCorrupt
			}
			w.pending[r.Tx] = append(w.pending[r.Tx], r)
		case "abort":
			if !active {
				return Result{}, ErrCorrupt
			}
			delete(w.pending, r.Tx)
		case "commit":
			replayed, err := w.commit(r.Tx, r.Sequence)
			if err != nil {
				return Result{}, err
			}
			if replayed {
				out.Replayed = append(out.Replayed, r.Tx)
			} else {
				out.Committed = append(out.Committed, r.Tx)
			}
		}
	}
	for tx := range w.pending {
		out.Discarded = append(out.Discarded, tx)
	}
	sort.Strings(out.Discarded)
	out.State = w.snapshot(sequence)
	return out, nil
}
