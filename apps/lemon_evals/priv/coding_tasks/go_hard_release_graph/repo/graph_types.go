package releasegraph

type Graph struct {
	packages map[string]Package
	order    []string
	reverse  map[string][]string
	groups   map[string][]string
}
