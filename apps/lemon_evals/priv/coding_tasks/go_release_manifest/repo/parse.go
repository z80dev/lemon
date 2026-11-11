package manifest

import (
	"bufio"
	"io"
	"strings"
)

func Parse(input io.Reader) ([]Entry, error) {
	s := bufio.NewScanner(input)
	var out []Entry
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		pair := strings.SplitN(line, "=", 2)
		if len(pair) != 2 {
			return nil, &ParseError{len(out) + 1, "missing equals"}
		}
		out = append(out, Entry{strings.TrimSpace(pair[0]), strings.TrimSpace(pair[1])})
	}
	return out, s.Err()
}
