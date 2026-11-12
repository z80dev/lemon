package releasegraph

func (g *Graph) waves(releases []Release) [][]string {
	out := [][]string{}
	for _, r := range releases {
		out = append(out, []string{r.Name})
	}
	return out
}
