package releasegraph

const versionLimit = 1000000000

func validVersion(v Version) bool {
	return v.Major >= 0 && v.Minor >= 0 && v.Patch >= 0 && v.Major <= versionLimit && v.Minor <= versionLimit && v.Patch <= versionLimit
}
func validatePackages(packages []Package) error {
	invalid := map[string]bool{}
	duplicates := map[string]bool{}
	byName := map[string]Package{}
	for _, p := range packages {
		if !nameOK(p.Name) || !validVersion(p.Version) || (p.Group != "" && !nameOK(p.Group)) {
			invalid[p.Name] = true
		}
		if _, ok := byName[p.Name]; ok {
			duplicates[p.Name] = true
		}
		byName[p.Name] = p
	}
	if len(invalid) > 0 {
		return &ValidationError{Code: "package", Names: sortedKeys(invalid)}
	}
	if len(duplicates) > 0 {
		return &ValidationError{Code: "duplicate", Names: sortedKeys(duplicates)}
	}
	for _, p := range packages {
		seen := map[string]bool{}
		for _, d := range p.Dependencies {
			_, exists := byName[d.Name]
			if !exists || d.Name == p.Name || seen[d.Name] || (d.Kind != "runtime" && d.Kind != "build" && d.Kind != "dev") || (d.Policy != "pin" && d.Policy != "compatible" && d.Policy != "any") {
				invalid[p.Name] = true
			}
			seen[d.Name] = true
		}
	}
	if len(invalid) > 0 {
		return &ValidationError{Code: "dependency", Names: sortedKeys(invalid)}
	}
	return nil
}
