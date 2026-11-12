package releasegraph

func propagated(d Dependency, rank int) int {
	if d.Kind == "dev" || rank == 0 {
		return 0
	}
	return 1
}
