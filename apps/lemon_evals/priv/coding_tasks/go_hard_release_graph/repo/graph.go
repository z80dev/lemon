package releasegraph

func Build(packages []Package) (*Graph, error) {
	if err := validatePackages(packages); err != nil {
		return nil, err
	}
	g := &Graph{packages: map[string]Package{}, reverse: map[string][]string{}, groups: map[string][]string{}}
	for _, p := range packages {
		g.packages[p.Name] = clonePackage(p)
	}
	g.reindex()
	if members := g.cycleMembers(); len(members) > 0 {
		return nil, &ValidationError{Code: "cycle", Names: members}
	}
	return g, nil
}
func (g *Graph) Packages() []Package {
	out := make([]Package, 0, len(g.order))
	for _, n := range g.order {
		out = append(out, clonePackage(g.packages[n]))
	}
	return out
}
