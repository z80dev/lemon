package releasegraph

func (e *Engine) Snapshot() Snapshot {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return Snapshot{Revision: e.revision, Packages: e.graph.Packages()}
}
func Restore(s Snapshot) (*Engine, error) {
	if s.Revision == 0 {
		return nil, ErrInvalid
	}
	g, err := Build(s.Packages)
	if err != nil {
		return nil, err
	}
	return &Engine{graph: g, revision: s.Revision}, nil
}
