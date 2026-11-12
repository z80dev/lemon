package ledger

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
)

func snapshotDigest(s Snapshot) string {
	s = canonical(s)
	s.Digest = ""
	data, _ := json.Marshal(s)
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
func transactionDigest(ops []Record) string {
	copyOps := append([]Record{}, ops...)
	for i := range copyOps {
		copyOps[i].Sequence = 0
		copyOps[i].Tx = ""
	}
	data, _ := json.Marshal(copyOps)
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
