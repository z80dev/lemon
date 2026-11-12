package releasegraph

func (g *Graph) seed(req Request) (map[string]int, map[string]map[string]bool, error) {
	levels := map[string]int{}
	reasons := map[string]map[string]bool{}
	for _, c := range req.Changes {
		if _, ok := g.packages[c.Name]; !ok || Rank(c.Level) < 0 {
			return nil, nil, ErrInvalid
		}
		if Rank(c.Level) > levels[c.Name] {
			levels[c.Name] = Rank(c.Level)
		}
		if Rank(c.Level) > 0 {
			addReason(reasons, c.Name, "direct")
		}
	}
	return levels, reasons, nil
}
