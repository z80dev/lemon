package releasegraph

func (e *Engine) Apply(update Update) (Snapshot, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if update.Expected != e.revision {
		return Snapshot{}, ErrConflict
	}
	for _, edit := range update.Edits {
		if edit.Remove != "" {
			delete(e.graph.packages, edit.Remove)
		}
		if edit.Upsert != nil {
			e.graph.packages[edit.Upsert.Name] = clonePackage(*edit.Upsert)
		}
	}
	e.graph.reindex()
	e.revision++
	return Snapshot{Revision: e.revision, Packages: e.graph.Packages()}, nil
}
