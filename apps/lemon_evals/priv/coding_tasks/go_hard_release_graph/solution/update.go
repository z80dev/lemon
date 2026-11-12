package releasegraph

func (e *Engine) Apply(update Update) (Snapshot, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if update.Expected != e.revision {
		return Snapshot{}, ErrConflict
	}
	if e.revision == ^uint64(0) {
		return Snapshot{}, ErrInvalid
	}
	packages := map[string]Package{}
	for n, p := range e.graph.packages {
		packages[n] = p
	}
	seen := map[string]bool{}
	for _, edit := range update.Edits {
		if (edit.Remove == "") == (edit.Upsert == nil) {
			return Snapshot{}, ErrInvalid
		}
		name := edit.Remove
		if edit.Upsert != nil {
			name = edit.Upsert.Name
		}
		if seen[name] {
			return Snapshot{}, ErrInvalid
		}
		seen[name] = true
		if edit.Upsert != nil {
			packages[name] = clonePackage(*edit.Upsert)
		} else {
			if _, ok := packages[name]; !ok {
				return Snapshot{}, ErrInvalid
			}
			delete(packages, name)
		}
	}
	candidate := make([]Package, 0, len(packages))
	for _, p := range packages {
		candidate = append(candidate, p)
	}
	g, err := Build(candidate)
	if err != nil {
		return Snapshot{}, err
	}
	e.graph = g
	e.revision++
	return Snapshot{Revision: e.revision, Packages: g.Packages()}, nil
}
