package ledger

func (w *working) commit(tx string, sequence uint64) (bool, error) {
	ops, ok := w.pending[tx]
	if !ok {
		return false, ErrCorrupt
	}
	next, err := applyOperations(w.accounts, ops)
	if err != nil {
		return false, err
	}
	w.accounts = next
	w.receipts[tx] = Receipt{Tx: tx, Digest: transactionDigest(ops), Sequence: sequence}
	delete(w.pending, tx)
	return false, nil
}
