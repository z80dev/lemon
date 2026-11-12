package releasegraph

func validatePackages(packages []Package) error {
	for _, p := range packages {
		if !nameOK(p.Name) {
			return &ValidationError{Code: "package", Names: []string{p.Name}}
		}
	}
	return nil
}
