package ledger

import "sync"

type Engine struct {
	mu    sync.RWMutex
	state Snapshot
}

func NewEngine(initial Snapshot) (*Engine, error) {
	s, err := ValidateSnapshot(initial)
	if err != nil {
		return nil, err
	}
	return &Engine{state: s}, nil
}
func (e *Engine) Snapshot() Snapshot {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return cloneSnapshot(e.state)
}
func (e *Engine) Recover(expected uint64, data []byte) (Result, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if expected != e.state.Sequence {
		return Result{}, ErrConflict
	}
	result, err := Recover(e.state, data)
	if err != nil {
		return Result{}, err
	}
	e.state = cloneSnapshot(result.State)
	return result, nil
}
