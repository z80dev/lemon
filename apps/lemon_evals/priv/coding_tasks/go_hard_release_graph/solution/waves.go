package releasegraph

func (g *Graph) waves(releases []Release) [][]string {
	pending := map[string]bool{}
	for _, r := range releases {
		pending[r.Name] = true
	}
	out := [][]string{}
	for len(pending) > 0 {
		ready := []string{}
		for _, n := range sortedKeys(pending) {
			blocked := false
			for _, d := range g.packages[n].Dependencies {
				if d.Kind != "dev" && pending[d.Name] {
					blocked = true
					break
				}
			}
			if !blocked {
				ready = append(ready, n)
			}
		}
		out = append(out, ready)
		for _, n := range ready {
			delete(pending, n)
		}
	}
	return out
}
