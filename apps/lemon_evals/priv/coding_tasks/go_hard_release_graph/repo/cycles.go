package releasegraph

func (g *Graph) cycleMembers() []string {
	active := map[string]bool{}
	done := map[string]bool{}
	var visit func(string) []string
	visit = func(name string) []string {
		if active[name] {
			return []string{name}
		}
		if done[name] {
			return nil
		}
		active[name] = true
		for _, d := range g.packages[name].Dependencies {
			if d.Kind == "runtime" {
				if cycle := visit(d.Name); len(cycle) > 0 {
					return cycle
				}
			}
		}
		active[name] = false
		done[name] = true
		return nil
	}
	for _, name := range g.order {
		if cycle := visit(name); len(cycle) > 0 {
			return cycle
		}
	}
	return []string{}
}
