package releasegraph

func (g *Graph) cycleMembers() []string {
	// Tarjan: report every cyclic SCC, not just a traversal-dependent witness.
	next := 0
	index := map[string]int{}
	low := map[string]int{}
	active := map[string]bool{}
	stack := []string{}
	members := map[string]bool{}
	var visit func(string)
	visit = func(n string) {
		next++
		index[n] = next
		low[n] = next
		stack = append(stack, n)
		active[n] = true
		for _, d := range g.packages[n].Dependencies {
			if d.Kind == "dev" {
				continue
			}
			if index[d.Name] == 0 {
				visit(d.Name)
				if low[d.Name] < low[n] {
					low[n] = low[d.Name]
				}
			} else if active[d.Name] && index[d.Name] < low[n] {
				low[n] = index[d.Name]
			}
		}
		if low[n] == index[n] {
			component := []string{}
			for {
				last := stack[len(stack)-1]
				stack = stack[:len(stack)-1]
				active[last] = false
				component = append(component, last)
				if last == n {
					break
				}
			}
			if len(component) > 1 {
				for _, name := range component {
					members[name] = true
				}
			}
		}
	}
	for _, n := range g.order {
		if index[n] == 0 {
			visit(n)
		}
	}
	return sortedKeys(members)
}
