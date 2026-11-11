package routes

import (
	"fmt"
	"strings"
)

type Table struct{ rules []Rule }

func New(rules []Rule) (*Table, error) {
	t := &Table{}
	for _, r := range rules {
		prefix, ok := canonical(r.Prefix)
		if !ok || r.NextHop == "" {
			return nil, fmt.Errorf("%w", ErrInvalid)
		}
		r.Prefix = prefix
		t.rules = append(t.rules, r)
	}
	return t, nil
}
func (t *Table) Lookup(input string) (string, bool) {
	p, ok := canonical(input)
	if !ok {
		return "", false
	}
	best := -1
	for i, r := range t.rules {
		if p != r.Prefix && r.Prefix != "/" && !strings.HasPrefix(p, r.Prefix+"/") {
			continue
		}
		if best < 0 || len(r.Prefix) > len(t.rules[best].Prefix) || len(r.Prefix) == len(t.rules[best].Prefix) && r.Priority > t.rules[best].Priority {
			best = i
		}
	}
	if best < 0 {
		return "", false
	}
	return t.rules[best].NextHop, true
}
