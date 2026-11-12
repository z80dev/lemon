package releasegraph

import "sort"

func addReason(all map[string]map[string]bool, name, reason string) {
	if all[name] == nil {
		all[name] = map[string]bool{}
	}
	all[name][reason] = true
}
func reasonList(in map[string]bool) []string {
	out := []string{}
	for s := range in {
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}
