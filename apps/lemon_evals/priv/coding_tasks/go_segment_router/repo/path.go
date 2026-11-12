package routes

import (
	"path"
	"strings"
)

func canonical(s string) (string, bool) {
	if s == "" || s[0] != '/' || strings.ContainsAny(s, "?#\x00") {
		return "", false
	}
	return path.Clean(s), true
}
