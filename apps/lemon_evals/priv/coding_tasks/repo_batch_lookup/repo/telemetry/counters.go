package telemetry

import "sync"

type Call struct { Operation string; Keys []string }
type Counters struct {
    mu sync.Mutex
    calls []Call
}
func (c *Counters) Record(operation string, keys []string) {
    if c == nil { return }
    c.mu.Lock()
    defer c.mu.Unlock()
    c.calls = append(c.calls,Call{Operation:operation,Keys:append([]string(nil),keys...)})
}
func (c *Counters) Calls() []Call {
    c.mu.Lock()
    defer c.mu.Unlock()
    result := make([]Call,len(c.calls))
    for i,call := range c.calls { result[i]=Call{Operation:call.Operation,Keys:append([]string(nil),call.Keys...)} }
    return result
}
