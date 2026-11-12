package releasegraph

import "sync"

type Engine struct {
	mu       sync.RWMutex
	graph    *Graph
	revision uint64
}

func NewEngine(packages []Package) (*Engine, error) {
	g, err := Build(packages)
	if err != nil {
		return nil, err
	}
	return &Engine{graph: g, revision: 1}, nil
}
func (e *Engine) Plan(req Request) (Plan, error) {
	e.mu.RLock()
	defer e.mu.RUnlock()
	p, err := e.graph.Plan(req)
	if err == nil {
		p.Revision = e.revision
	}
	return p, err
}
