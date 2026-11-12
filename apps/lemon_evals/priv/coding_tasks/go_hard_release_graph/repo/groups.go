package releasegraph

func (g *Graph) expandGroups(levels map[string]int, reasons map[string]map[string]bool) bool {
	changed := false
	for group, names := range g.groups {
		active := false
		for _, name := range names {
			if levels[name] > 0 {
				active = true
			}
		}
		if !active {
			continue
		}
		for _, name := range names {
			if levels[name] == 0 {
				levels[name] = 1
				addReason(reasons, name, "group:"+group)
				changed = true
			}
		}
	}
	return changed
}
