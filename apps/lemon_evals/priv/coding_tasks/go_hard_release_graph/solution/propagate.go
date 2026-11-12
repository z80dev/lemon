package releasegraph

func (g *Graph) propagate(levels map[string]int, reasons map[string]map[string]bool) {
	for {
		changed := g.expandGroups(levels, reasons)
		for _, name := range g.order {
			for _, d := range g.packages[name].Dependencies {
				rank := propagated(d, levels[d.Name])
				if rank == 0 {
					continue
				}
				addReason(reasons, name, "dependency:"+d.Name)
				if levels[name] < rank {
					levels[name] = rank
					changed = true
				}
			}
		}
		if !changed {
			return
		}
	}
}
