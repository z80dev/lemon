package releasegraph

func (g *Graph) expandGroups(levels map[string]int, reasons map[string]map[string]bool) bool {
	changed := false
	for group, names := range g.groups {
		max := 0
		for _, n := range names {
			if levels[n] > max {
				max = levels[n]
			}
		}
		if max == 0 || len(names) < 2 {
			continue
		}
		for _, n := range names {
			if levels[n] < max {
				levels[n] = max
				changed = true
			}
			addReason(reasons, n, "group:"+group)
		}
	}
	return changed
}
