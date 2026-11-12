package ledger

import "sync"

type Memory struct {
    mu sync.RWMutex
    dispatches map[key]DispatchRow
    events map[key][]EventRow
}
func New() *Memory {
    return &Memory{dispatches:make(map[key]DispatchRow), events:make(map[key][]EventRow)}
}
