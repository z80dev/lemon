package releasegraph

func propagated(d Dependency, rank int) int {
	if rank == 0 || d.Kind == "dev" {
		return 0
	}
	if d.Kind == "build" || d.Policy == "pin" {
		return 1
	}
	if d.Policy == "compatible" && rank == 3 {
		return 2
	}
	return 0
}
