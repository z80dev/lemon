package ledger

func (m *Memory) Put(row DispatchRow) {
    m.mu.Lock()
    defer m.mu.Unlock()
    m.dispatches[rowKey(row.Account, row.ID)] = row
}
func (m *Memory) Append(row EventRow) {
    m.mu.Lock()
    defer m.mu.Unlock()
    k := rowKey(row.Account, row.DispatchID)
    m.events[k] = append(m.events[k], row)
}
