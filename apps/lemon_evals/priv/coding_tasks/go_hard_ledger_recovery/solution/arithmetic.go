package ledger

import "math"

func add(a, b int64) (int64, error) {
	if (b > 0 && a > math.MaxInt64-b) || (b < 0 && a < math.MinInt64-b) {
		return 0, ErrInvalid
	}
	return a + b, nil
}
