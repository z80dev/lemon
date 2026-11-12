package releasegraph

import "sort"

func (g *Graph) reindex() {
	g.order = make([]string, 0, len(g.packages))
	g.reverse = map[string][]string{}
	g.groups = map[string][]string{}
	for n, p := range g.packages {
		g.order = append(g.order, n)
		if p.Group != "" {
			g.groups[p.Group] = append(g.groups[p.Group], n)
		}
		for _, d := range p.Dependencies {
			if d.Kind != "dev" {
				g.reverse[d.Name] = append(g.reverse[d.Name], n)
			}
		}
	}
	sort.Strings(g.order)
	for _, v := range g.reverse {
		sort.Strings(v)
	}
	for _, v := range g.groups {
		sort.Strings(v)
	}
}
