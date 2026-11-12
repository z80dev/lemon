package routes

import (
	"fmt"
	"strings"
)

type node struct {
	children map[string]*node
	target   string
	priority int
	present  bool
}
type Table struct{ root node }

func New(rules []Rule) (*Table, error) {
	t := &Table{}
	for _, r := range rules {
		prefix, ok := canonical(r.Prefix)
		if !ok || r.NextHop == "" {
			return nil, fmt.Errorf("%w", ErrInvalid)
		}
		n := &t.root
		if prefix != "/" {
			for _, segment := range strings.Split(prefix[1:], "/") {
				if n.children == nil {
					n.children = map[string]*node{}
				}
				child := n.children[segment]
				if child == nil {
					child = &node{}
					n.children[segment] = child
				}
				n = child
			}
		}
		if !n.present || r.Priority > n.priority {
			n.target = r.NextHop
			n.priority = r.Priority
			n.present = true
		}
	}
	return t, nil
}
func (t *Table) Lookup(input string) (string, bool) {
	p, ok := canonical(input)
	if !ok {
		return "", false
	}
	n := &t.root
	target, found := n.target, n.present
	if p == "/" {
		return target, found
	}
	remaining := p[1:]
	for remaining != "" {
		part, rest, more := strings.Cut(remaining, "/")
		n = n.children[part]
		if n == nil {
			break
		}
		if n.present {
			target, found = n.target, true
		}
		if !more {
			break
		}
		remaining = rest
	}
	return target, found
}
