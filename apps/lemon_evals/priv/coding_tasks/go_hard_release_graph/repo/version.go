package releasegraph

func bump(v Version, rank int) Version {
	switch rank {
	case 1:
		v.Patch++
	case 2:
		v.Minor++
		v.Patch = 0
	case 3:
		v.Major++
		v.Minor = 0
		v.Patch = 0
	}
	return v
}
