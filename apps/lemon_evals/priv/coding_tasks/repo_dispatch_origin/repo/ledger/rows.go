package ledger

import "time"

type DispatchRow struct {
    Account string
    ID string
    Reference string
    Status string
}
type EventRow struct {
    Account string
    DispatchID string
    Kind string
    Hub string
    At time.Time
    Sequence int64
}
