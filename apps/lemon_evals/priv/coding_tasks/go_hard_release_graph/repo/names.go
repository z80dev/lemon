package releasegraph

import "regexp"

var validName = regexp.MustCompile(`^[a-z][a-z0-9_-]*$`)

func nameOK(s string) bool { return validName.MatchString(s) }
