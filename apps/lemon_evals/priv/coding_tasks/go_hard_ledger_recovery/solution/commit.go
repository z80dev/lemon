package ledger

func (w *working) commit(tx string, sequence uint64) (bool, error) {
	ops, exists := w.pending[tx]
	if !exists {
		return false, ErrCorrupt
	}
	digest := transactionDigest(ops)
	if receipt, exists := w.receipts[tx]; exists {
		if receipt.Digest != digest {
			return false, ErrCorrupt
		}
		delete(w.pending, tx)
		return true, nil
	}
	next, err := applyOperations(w.accounts, ops)
	if err != nil {
		return false, err
	}
	w.accounts = next
	w.receipts[tx] = Receipt{Tx: tx, Digest: digest, Sequence: sequence}
	delete(w.pending, tx)
	return false, nil
}
