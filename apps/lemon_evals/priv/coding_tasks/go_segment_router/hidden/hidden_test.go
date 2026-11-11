package routes

import (
	"errors"
	"fmt"
	"math/rand"
	"sync"
	"testing"
)

func TestRouteSemantics(t *testing.T) {
	rules := []Rule{{"/", "root", 100}, {"/a//b/", "first", 2}, {"/a/c/../b", "tie", 2}, {"/a/b", "winner", 3}, {"/a/b/c", "deep", -9}, {"/a", "short", 1000}, {"/A", "upper", 0}, {"/%61", "literal", 0}}
	tab, err := New(rules)
	if err != nil {
		t.Fatal(err)
	}
	rules[0].NextHop = "changed"
	rules[3].Prefix = "/other"
	for _, c := range []struct{ path, want string }{{"/a/b", "winner"}, {"/a/bc", "short"}, {"/a/b/c/x", "deep"}, {"//a/./b/q/../", "winner"}, {"/unmatched", "root"}, {"/A/x", "upper"}, {"/%61", "literal"}, {"/a/../../", "root"}} {
		got, ok := tab.Lookup(c.path)
		if !ok || got != c.want {
			t.Fatalf("%q: %q %v want %s", c.path, got, ok, c.want)
		}
	}
	for _, p := range []string{"", "relative", "/x?q", "/x#f", "/x\x00z"} {
		if got, ok := tab.Lookup(p); ok || got != "" {
			t.Fatalf("invalid %q", p)
		}
	}
	for _, rules := range [][]Rule{{{"x", "a", 0}}, {{"/x?", "a", 0}}, {{"/x", "", 0}}} {
		if got, err := New(rules); got != nil || !errors.Is(err, ErrInvalid) {
			t.Fatal("invalid rule")
		}
	}
	empty, _ := New(nil)
	if got, ok := empty.Lookup("/x"); ok || got != "" {
		t.Fatal("empty table")
	}
	only, _ := New([]Rule{{"/a", "first", 0}, {"/a/", "second", 0}})
	if got, ok := only.Lookup("/a"); !ok || got != "first" {
		t.Fatal("tie")
	}
	if _, ok := only.Lookup("/ab"); ok {
		t.Fatal("segment boundary")
	}
	var wg sync.WaitGroup
	for n := 0; n < 16; n++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 1000; i++ {
				if got, _ := tab.Lookup("/a/b/c/x"); got != "deep" {
					t.Error("concurrent lookup")
				}
			}
		}()
	}
	wg.Wait()
}
func TestScaleIndex(t *testing.T) {
	const count = 200000
	rules := make([]Rule, 0, count+1)
	rules = append(rules, Rule{"/", "fallback", 0})
	for i := 0; i < count; i++ {
		rules = append(rules, Rule{fmt.Sprintf("/organizations/team-%06d/exports/private", i), fmt.Sprintf("hop-%d", i), i % 7})
	}
	table, err := New(rules)
	if err != nil {
		t.Fatal(err)
	}
	r := rand.New(rand.NewSource(93))
	for i := 0; i < 80000; i++ {
		n := r.Intn(count)
		query := fmt.Sprintf("/organizations/team-%06d/exports/private/record", n)
		got, ok := table.Lookup(query)
		if !ok || got != fmt.Sprintf("hop-%d", n) {
			t.Fatalf("lookup %s: %q %v", query, got, ok)
		}
	}
}
