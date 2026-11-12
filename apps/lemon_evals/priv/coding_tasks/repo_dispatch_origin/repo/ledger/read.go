package ledger

import "example.com/dispatch/model"

func (m *Memory) Dispatch(account, id string) (DispatchRow, error) {
    m.mu.RLock()
    defer m.mu.RUnlock()
    row, ok := m.dispatches[rowKey(account,id)]
    if !ok { return DispatchRow{}, model.ErrNotFound }
    return row, nil
}
func (m *Memory) Events(account, id string) ([]EventRow, error) {
    m.mu.RLock()
    defer m.mu.RUnlock()
    return append([]EventRow(nil), m.events[rowKey(account,id)]...), nil
}
