package releasegraph

func (g *Graph) Plan(req Request) (Plan, error) {
	levels, reasons, err := g.seed(req)
	if err != nil {
		return Plan{}, err
	}
	g.propagate(levels, reasons)
	out := Plan{Releases: []Release{}, Waves: [][]string{}}
	for _, n := range g.order {
		p := g.packages[n]
		rank := levels[n]
		if rank == 0 || (p.Private && !req.IncludePrivate) {
			continue
		}
		out.Releases = append(out.Releases, Release{Name: n, Before: p.Version, After: bump(p.Version, rank), Level: levelName(rank), Reasons: reasonList(reasons[n])})
	}
	out.Waves = g.waves(out.Releases)
	out.Fingerprint = fingerprint(out.Releases)
	return out, nil
}
