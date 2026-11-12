package releasegraph

func Rank(level string) int {
	switch level {
	case "none":
		return 0
	case "patch":
		return 1
	case "minor":
		return 2
	case "major":
		return 3
	}
	return -1
}
func levelName(rank int) string { return []string{"none", "patch", "minor", "major"}[rank] }
