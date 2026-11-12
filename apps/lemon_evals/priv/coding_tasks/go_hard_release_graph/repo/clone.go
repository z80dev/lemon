package releasegraph

func clonePackage(p Package) Package {
	p.Dependencies = append([]Dependency{}, p.Dependencies...)
	return p
}
func clonePackages(in []Package) []Package {
	out := make([]Package, len(in))
	for i, p := range in {
		out[i] = clonePackage(p)
	}
	return out
}
