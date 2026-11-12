package releasegraph

func (g *Graph) propagate(levels map[string]int, reasons map[string]map[string]bool) {
	g.expandGroups(levels, reasons)
	for _, source := range g.order {
		if levels[source] == 0 {
			continue
		}
		for _, name := range g.reverse[source] {
			for _, d := range g.packages[name].Dependencies {
				if d.Name != source {
					continue
				}
				rank := propagated(d, levels[source])
				if levels[name] < rank {
					levels[name] = rank
					addReason(reasons, name, "dependency:"+source)
				}
			}
		}
	}
}
