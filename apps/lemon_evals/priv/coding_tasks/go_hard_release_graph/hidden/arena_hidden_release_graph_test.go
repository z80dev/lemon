package releasegraph_test

import (
	rg "arena/releasegraph"
	"arena/releasegraph/adapters/catalog"
	"arena/releasegraph/adapters/httpapi"
	"arena/releasegraph/adapters/jsonapi"
	"arena/releasegraph/app"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
)

func arenaHiddenRGPackage(name string, deps ...rg.Dependency) rg.Package {
	return rg.Package{Name: name, Version: rg.Version{Major: 1, Minor: 2, Patch: 3}, Dependencies: deps}
}
func arenaHiddenRGDep(name, kind, policy string) rg.Dependency {
	return rg.Dependency{Name: name, Kind: kind, Policy: policy}
}
func arenaHiddenRGGraph(t *testing.T, p []rg.Package) *rg.Graph {
	t.Helper()
	g, e := rg.Build(p)
	if e != nil {
		t.Fatal(e)
	}
	return g
}
func arenaHiddenRGValidation(t *testing.T, p []rg.Package, code string, names []string) {
	t.Helper()
	_, e := rg.Build(p)
	var v *rg.ValidationError
	if !errors.Is(e, rg.ErrInvalid) || !errors.As(e, &v) || v.Code != code || !reflect.DeepEqual(v.Names, names) {
		t.Fatalf("validation: %v %#v want %s %v", e, v, code, names)
	}
}
func TestArenaHiddenReleaseGraphValidation(t *testing.T) {
	a := arenaHiddenRGPackage("a")
	b := arenaHiddenRGPackage("b")
	c := arenaHiddenRGPackage("c")
	d := arenaHiddenRGPackage("d")
	bad := a
	bad.Name = "Bad"
	bad.Version.Patch = -1
	arenaHiddenRGValidation(t, []rg.Package{bad, bad}, "package", []string{"Bad"})
	bad = a
	bad.Version.Minor = 1000000001
	arenaHiddenRGValidation(t, []rg.Package{bad}, "package", []string{"a"})
	bad = a
	bad.Group = "Bad"
	arenaHiddenRGValidation(t, []rg.Package{bad}, "package", []string{"a"})
	arenaHiddenRGValidation(t, []rg.Package{b, a, b, a}, "duplicate", []string{"a", "b"})
	for _, dep := range []rg.Dependency{arenaHiddenRGDep("z", "runtime", "pin"), arenaHiddenRGDep("a", "dev", "pin"), arenaHiddenRGDep("b", "wrong", "pin"), arenaHiddenRGDep("b", "runtime", "wrong")} {
		bad = a
		bad.Dependencies = []rg.Dependency{dep}
		arenaHiddenRGValidation(t, []rg.Package{bad, b}, "dependency", []string{"a"})
	}
	bad = a
	bad.Dependencies = []rg.Dependency{arenaHiddenRGDep("b", "dev", "any"), arenaHiddenRGDep("b", "runtime", "pin")}
	arenaHiddenRGValidation(t, []rg.Package{bad, b}, "dependency", []string{"a"})
	a.Dependencies = []rg.Dependency{arenaHiddenRGDep("b", "runtime", "any")}
	b.Dependencies = []rg.Dependency{arenaHiddenRGDep("a", "build", "any")}
	c.Dependencies = []rg.Dependency{arenaHiddenRGDep("a", "runtime", "pin")}
	d.Dependencies = []rg.Dependency{arenaHiddenRGDep("e", "build", "pin")}
	e := arenaHiddenRGPackage("e", arenaHiddenRGDep("d", "runtime", "pin"))
	arenaHiddenRGValidation(t, []rg.Package{e, c, b, a, d}, "cycle", []string{"a", "b", "d", "e"})
	a.Dependencies[0].Kind = "dev"
	arenaHiddenRGGraph(t, []rg.Package{a, b, c})
	a = arenaHiddenRGPackage("a")
	b = arenaHiddenRGPackage("b")
	a.Group = "train"
	b.Group = "train"
	b.Version.Patch++
	arenaHiddenRGValidation(t, []rg.Package{b, a}, "group", []string{"a", "b"})
}
func TestArenaHiddenReleaseGraphFixedPoint(t *testing.T) {
	z := arenaHiddenRGPackage("z")
	z.Group = "train"
	z.Private = true
	a := arenaHiddenRGPackage("a")
	a.Group = "train"
	b := arenaHiddenRGPackage("b", arenaHiddenRGDep("a", "runtime", "compatible"))
	c := arenaHiddenRGPackage("c", arenaHiddenRGDep("b", "runtime", "pin"))
	d := arenaHiddenRGPackage("d", arenaHiddenRGDep("c", "build", "any"), arenaHiddenRGDep("z", "dev", "pin"))
	g := arenaHiddenRGGraph(t, []rg.Package{z, d, c, b, a})
	req := rg.Request{Changes: []rg.Change{{Name: "z", Level: "major"}, {Name: "c", Level: "major"}, {Name: "z", Level: "none"}}}
	p, e := g.Plan(req)
	if e != nil {
		t.Fatal(e)
	}
	want := []rg.Release{
		{Name: "a", Before: a.Version, After: rg.Version{Major: 2}, Level: "major", Reasons: []string{"group:train"}},
		{Name: "b", Before: b.Version, After: rg.Version{Major: 1, Minor: 3}, Level: "minor", Reasons: []string{"dependency:a"}},
		{Name: "c", Before: c.Version, After: rg.Version{Major: 2}, Level: "major", Reasons: []string{"dependency:b", "direct"}},
		{Name: "d", Before: d.Version, After: rg.Version{Major: 1, Minor: 2, Patch: 4}, Level: "patch", Reasons: []string{"dependency:c"}},
	}
	if !reflect.DeepEqual(p.Releases, want) || !reflect.DeepEqual(p.Waves, [][]string{{"a"}, {"b"}, {"c"}, {"d"}}) {
		t.Fatalf("%#v", p)
	}
	req.IncludePrivate = true
	p, e = g.Plan(req)
	if e != nil || len(p.Releases) != 5 || !reflect.DeepEqual(p.Releases[4].Reasons, []string{"direct", "group:train"}) {
		t.Fatal(p, e)
	}
	for _, bad := range []rg.Change{{Name: "missing", Level: "none"}, {Name: "a", Level: "Minor"}} {
		out, e := g.Plan(rg.Request{Changes: []rg.Change{bad}})
		if !errors.Is(e, rg.ErrInvalid) || !reflect.DeepEqual(out, rg.Plan{}) {
			t.Fatal(out, e)
		}
	}
}
func TestArenaHiddenReleaseGraphPolicyMatrix(t *testing.T) {
	for _, kind := range []string{"runtime", "build", "dev"} {
		for _, policy := range []string{"pin", "compatible", "any"} {
			for rank, level := range []string{"none", "patch", "minor", "major"} {
				a := arenaHiddenRGPackage("a")
				b := arenaHiddenRGPackage("b", arenaHiddenRGDep("a", kind, policy))
				g := arenaHiddenRGGraph(t, []rg.Package{b, a})
				p, e := g.Plan(rg.Request{Changes: []rg.Change{{Name: "a", Level: level}}})
				if e != nil {
					t.Fatal(e)
				}
				expected := ""
				if rank > 0 && kind != "dev" {
					if kind == "build" || policy == "pin" {
						expected = "patch"
					} else if policy == "compatible" && rank == 3 {
						expected = "minor"
					}
				}
				got := ""
				for _, r := range p.Releases {
					if r.Name == "b" {
						got = r.Level
					}
				}
				if got != expected {
					t.Fatalf("%s %s %s => %s want %s", kind, policy, level, got, expected)
				}
			}
		}
	}
}
func TestArenaHiddenReleaseGraphOracle(t *testing.T) {
	rng := rand.New(rand.NewSource(526))
	names := []string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"}
	labels := []string{"none", "patch", "minor", "major"}
	for trial := 0; trial < 60; trial++ {
		pkgs := make([]rg.Package, len(names))
		levels := make([]int, len(names))
		why := make([]map[string]bool, len(names))
		req := rg.Request{IncludePrivate: trial%2 == 0}
		for i, n := range names {
			p := arenaHiddenRGPackage(n)
			p.Private = i%5 == 0
			if i%4 == 0 {
				p.Group = "train"
			}
			for j := 0; j < i; j++ {
				if rng.Intn(4) == 0 {
					p.Dependencies = append(p.Dependencies, arenaHiddenRGDep(names[j], []string{"runtime", "build", "dev"}[rng.Intn(3)], []string{"pin", "compatible", "any"}[rng.Intn(3)]))
				}
			}
			pkgs[i] = p
			why[i] = map[string]bool{}
			levels[i] = rng.Intn(4)
			req.Changes = append(req.Changes, rg.Change{Name: n, Level: labels[levels[i]]})
			if levels[i] > 0 {
				why[i]["direct"] = true
			}
		}
		for changed := true; changed; {
			changed = false
			max := 0
			for i := range pkgs {
				if pkgs[i].Group != "" && levels[i] > max {
					max = levels[i]
				}
			}
			for i := range pkgs {
				if pkgs[i].Group != "" && max > 0 {
					why[i]["group:train"] = true
					if levels[i] < max {
						levels[i] = max
						changed = true
					}
				}
			}
			for i, p := range pkgs {
				for _, d := range p.Dependencies {
					j := sort.SearchStrings(names, d.Name)
					want := 0
					if levels[j] > 0 && d.Kind != "dev" {
						if d.Kind == "build" || d.Policy == "pin" {
							want = 1
						} else if d.Policy == "compatible" && levels[j] == 3 {
							want = 2
						}
					}
					if want > 0 {
						why[i]["dependency:"+d.Name] = true
					}
					if want > levels[i] {
						levels[i] = want
						changed = true
					}
				}
			}
		}
		rng.Shuffle(len(pkgs), func(i, j int) { pkgs[i], pkgs[j] = pkgs[j], pkgs[i] })
		g := arenaHiddenRGGraph(t, pkgs)
		plan, e := g.Plan(req)
		if e != nil {
			t.Fatal(e)
		}
		got := map[string]rg.Release{}
		for _, r := range plan.Releases {
			got[r.Name] = r
		}
		count := 0
		for i, n := range names {
			if levels[i] == 0 || (!req.IncludePrivate && i%5 == 0) {
				continue
			}
			count++
			r, ok := got[n]
			reasons := []string{}
			for s := range why[i] {
				reasons = append(reasons, s)
			}
			sort.Strings(reasons)
			v := rg.Version{Major: 1, Minor: 2, Patch: 3}
			switch levels[i] {
			case 1:
				v.Patch++
			case 2:
				v.Minor++
				v.Patch = 0
			case 3:
				v.Major++
				v.Minor = 0
				v.Patch = 0
			}
			if !ok || r.Level != labels[levels[i]] || r.After != v || !reflect.DeepEqual(r.Reasons, reasons) {
				t.Fatalf("trial %d %s: %#v want %d %v", trial, n, r, levels[i], reasons)
			}
		}
		if count != len(got) {
			t.Fatal("extra releases")
		}
		// Independently check whole ready layers, including omitted private edges.
		pending := map[string]bool{}
		for n := range got {
			pending[n] = true
		}
		for _, wave := range plan.Waves {
			ready := []string{}
			for _, p := range pkgs {
				if !pending[p.Name] {
					continue
				}
				blocked := false
				for _, d := range p.Dependencies {
					if d.Kind != "dev" && pending[d.Name] {
						blocked = true
					}
				}
				if !blocked {
					ready = append(ready, p.Name)
				}
			}
			sort.Strings(ready)
			if !reflect.DeepEqual(wave, ready) {
				t.Fatal(wave, ready)
			}
			for _, n := range wave {
				delete(pending, n)
			}
		}
		if len(pending) != 0 {
			t.Fatal("unscheduled")
		}
	}
}
func TestArenaHiddenReleaseGraphIdentityReport(t *testing.T) {
	g := arenaHiddenRGGraph(t, []rg.Package{arenaHiddenRGPackage("b"), arenaHiddenRGPackage("a")})
	p, _ := g.Plan(rg.Request{Changes: []rg.Change{{Name: "b", Level: "minor"}, {Name: "a", Level: "patch"}}})
	canonical := "a=1.2.4:direct\nb=1.3.0:direct\n"
	sum := sha256.Sum256([]byte(canonical))
	if p.Fingerprint != hex.EncodeToString(sum[:]) {
		t.Fatal(p.Fingerprint)
	}
	var b bytes.Buffer
	if e := rg.WriteReport(&b, p); e != nil || b.String() != "wave 1: a,b\na 1.2.3 -> 1.2.4 [direct]\nb 1.2.3 -> 1.3.0 [direct]\n" {
		t.Fatal(b.String(), e)
	}
	empty, _ := g.Plan(rg.Request{})
	sum = sha256.Sum256(nil)
	if empty.Releases == nil || empty.Waves == nil || empty.Fingerprint != hex.EncodeToString(sum[:]) {
		t.Fatal(empty)
	}
	if e := rg.WriteReport(arenaHiddenRGWriter{}, p); !errors.Is(e, io.ErrClosedPipe) {
		t.Fatal(e)
	}
	a := arenaHiddenRGPackage("a")
	a.Version.Patch = 1000000000
	a.Private = true
	g = arenaHiddenRGGraph(t, []rg.Package{a})
	p, e := g.Plan(rg.Request{Changes: []rg.Change{{Name: "a", Level: "patch"}}})
	if !errors.Is(e, rg.ErrInvalid) || !reflect.DeepEqual(p, rg.Plan{}) {
		t.Fatal(p, e)
	}
}

type arenaHiddenRGWriter struct{}

func (arenaHiddenRGWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

type arenaHiddenRGReader struct{}

func (arenaHiddenRGReader) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }
func TestArenaHiddenReleaseGraphAtomicEngine(t *testing.T) {
	a := arenaHiddenRGPackage("a")
	b := arenaHiddenRGPackage("b", arenaHiddenRGDep("a", "runtime", "pin"))
	engine, e := rg.NewEngine([]rg.Package{a, b})
	if e != nil {
		t.Fatal(e)
	}
	before := engine.Snapshot()
	for _, u := range []rg.Update{
		{Expected: 1, Edits: []rg.Edit{{Remove: "a"}}},
		{Expected: 1, Edits: []rg.Edit{{Remove: "absent"}}},
		{Expected: 1, Edits: []rg.Edit{{}}},
		{Expected: 1, Edits: []rg.Edit{{Remove: "a", Upsert: &a}}},
		{Expected: 1, Edits: []rg.Edit{{Remove: "b"}, {Upsert: &b}}},
	} {
		s, e := engine.Apply(u)
		if !errors.Is(e, rg.ErrInvalid) || !reflect.DeepEqual(s, rg.Snapshot{}) || !reflect.DeepEqual(before, engine.Snapshot()) {
			t.Fatal(s, e, engine.Snapshot())
		}
	}
	if _, e := engine.Apply(rg.Update{Expected: 9, Edits: []rg.Edit{{}}}); !errors.Is(e, rg.ErrConflict) {
		t.Fatal(e)
	}
	c := arenaHiddenRGPackage("c")
	b.Dependencies = []rg.Dependency{arenaHiddenRGDep("c", "build", "any")}
	s, e := engine.Apply(rg.Update{Expected: 1, Edits: []rg.Edit{{Upsert: &b}, {Remove: "a"}, {Upsert: &c}}})
	if e != nil || s.Revision != 2 {
		t.Fatal(s, e)
	}
	b.Dependencies[0].Name = "lost"
	s.Packages[0].Dependencies[0].Name = "lost"
	p, e := engine.Plan(rg.Request{Changes: []rg.Change{{Name: "c", Level: "patch"}}})
	if e != nil || p.Revision != 2 || len(p.Releases) != 2 || p.Releases[0].Name != "b" {
		t.Fatal(p, e)
	}
	p.Releases[0].Reasons[0] = "lost"
	p.Waves[0][0] = "lost"
	fresh, _ := engine.Plan(rg.Request{Changes: []rg.Change{{Name: "c", Level: "patch"}}})
	if fresh.Releases[0].Reasons[0] != "dependency:c" {
		t.Fatal(fresh)
	}
	restored, e := rg.Restore(engine.Snapshot())
	if e != nil {
		t.Fatal(e)
	}
	rp, _ := restored.Plan(rg.Request{Changes: []rg.Change{{Name: "c", Level: "patch"}}})
	if !reflect.DeepEqual(rp, fresh) {
		t.Fatal(rp, fresh)
	}
	s, e = engine.Apply(rg.Update{Expected: 2})
	if e != nil || s.Revision != 3 {
		t.Fatal(s, e)
	}
	if _, e = rg.Restore(rg.Snapshot{}); !errors.Is(e, rg.ErrInvalid) {
		t.Fatal(e)
	}
	overflow, _ := rg.Restore(rg.Snapshot{Revision: ^uint64(0)})
	if _, e = overflow.Apply(rg.Update{Expected: ^uint64(0)}); !errors.Is(e, rg.ErrInvalid) {
		t.Fatal(e)
	}
	// Group replacement is validated after the entire transaction, and reindexes group membership.
	a = arenaHiddenRGPackage("a")
	b = arenaHiddenRGPackage("b")
	a.Group = "train"
	b.Group = "train"
	engine, _ = rg.NewEngine([]rg.Package{a, b})
	a.Version.Major = 2
	b.Version.Major = 2
	if _, e = engine.Apply(rg.Update{Expected: 1, Edits: []rg.Edit{{Upsert: &a}, {Upsert: &b}}}); e != nil {
		t.Fatal(e)
	}
	p, _ = engine.Plan(rg.Request{Changes: []rg.Change{{Name: "b", Level: "minor"}}})
	if len(p.Releases) != 2 || p.Releases[0].After.Minor != 3 {
		t.Fatal(p)
	}
}
func TestArenaHiddenReleaseGraphConcurrent(t *testing.T) {
	e, _ := rg.NewEngine([]rg.Package{arenaHiddenRGPackage("a")})
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 40; j++ {
				p, err := e.Plan(rg.Request{Changes: []rg.Change{{Name: "a", Level: "patch"}}})
				if err != nil || p.Revision == 0 || len(p.Releases) != 1 {
					t.Error(p, err)
				}
				s := e.Snapshot()
				s.Packages[0].Name = "changed"
			}
		}()
	}
	for i := 0; i < 40; i++ {
		s := e.Snapshot()
		if _, err := e.Apply(rg.Update{Expected: s.Revision}); err != nil {
			t.Fatal(err)
		}
	}
	wg.Wait()
}
func TestArenaHiddenReleaseGraphStrictJSON(t *testing.T) {
	readers := []func(string) error{
		func(s string) error { _, e := jsonapi.ReadRequest(strings.NewReader(s)); return e }, func(s string) error { _, e := jsonapi.ReadUpdate(strings.NewReader(s)); return e }, func(s string) error { _, e := jsonapi.ReadSnapshot(strings.NewReader(s)); return e },
	}
	for _, read := range readers {
		for _, s := range []string{`{"unknown":1}`, `{} {}`, `{} trailing`} {
			if e := read(s); e == nil {
				t.Fatal(s)
			}
		}
		if e := read("{} \n\t"); e != nil {
			t.Fatal(e)
		}
	}
	for _, s := range []string{`[{"name":"a","oops":1}]`, `[{"name":"a","version":{"oops":1}}]`, `[] []`, `[] x`} {
		if _, e := jsonapi.ReadPackages(strings.NewReader(s)); e == nil {
			t.Fatal(s)
		}
	}
	if _, e := jsonapi.ReadRequest(strings.NewReader(`{"changes":[{"name":"a","level":"patch","oops":1}]}`)); e == nil {
		t.Fatal("nested")
	}
	if _, e := jsonapi.ReadRequest(arenaHiddenRGReader{}); !errors.Is(e, io.ErrUnexpectedEOF) {
		t.Fatal(e)
	}
	if e := jsonapi.WritePlan(arenaHiddenRGWriter{}, rg.Plan{}); !errors.Is(e, io.ErrClosedPipe) {
		t.Fatal(e)
	}
	if e := jsonapi.WriteSnapshot(arenaHiddenRGWriter{}, rg.Snapshot{}); !errors.Is(e, io.ErrClosedPipe) {
		t.Fatal(e)
	}
}
func TestArenaHiddenReleaseGraphIntegrations(t *testing.T) {
	dir := t.TempDir()
	packages := []rg.Package{arenaHiddenRGPackage("a"), arenaHiddenRGPackage("b", arenaHiddenRGDep("a", "runtime", "pin"))}
	for i, p := range packages {
		b, _ := json.Marshal(p)
		if e := os.WriteFile(filepath.Join(dir, fmt.Sprintf("%d.json", i)), b, 0600); e != nil {
			t.Fatal(e)
		}
	}
	os.WriteFile(filepath.Join(dir, "ignore.txt"), []byte("invalid"), 0600)
	os.Mkdir(filepath.Join(dir, "nested.json"), 0700)
	loaded, e := catalog.Load(os.DirFS(dir), ".")
	if e != nil || !reflect.DeepEqual(loaded, packages) {
		t.Fatal(loaded, e)
	}
	if _, e = catalog.Load(os.DirFS(dir), "absent"); e == nil {
		t.Fatal("missing directory")
	}
	g := arenaHiddenRGGraph(t, loaded)
	req := `{"changes":[{"name":"a","level":"major"}]}`
	parsed, _ := jsonapi.ReadRequest(strings.NewReader(req))
	want, _ := g.Plan(parsed)
	array, _ := json.Marshal(packages)
	file := filepath.Join(dir, "catalog.input")
	os.WriteFile(file, array, 0600)
	var out, stderr bytes.Buffer
	if code := app.Run([]string{"plan", file}, strings.NewReader(req), &out, &stderr); code != 0 {
		t.Fatal(code, stderr.String())
	}
	var got rg.Plan
	if e = json.Unmarshal(out.Bytes(), &got); e != nil || !reflect.DeepEqual(got, want) {
		t.Fatal(got, e)
	}
	out.Reset()
	if app.Run([]string{"report", file}, strings.NewReader(req), &out, &stderr) != 0 {
		t.Fatal(stderr.String())
	}
	var report bytes.Buffer
	rg.WriteReport(&report, want)
	if out.String() != report.String() {
		t.Fatal(out.String(), report.String())
	}
	for _, body := range []string{`{"changes":[{"name":"missing","level":"none"}]}`, `{} {}`} {
		out.Reset()
		stderr.Reset()
		if code := app.Run([]string{"plan", file}, strings.NewReader(body), &out, &stderr); code != 1 || out.Len() != 0 || stderr.Len() == 0 {
			t.Fatal(code, out.String(), stderr.String())
		}
	}
	if code := app.Run([]string{"plan", file}, strings.NewReader(req), arenaHiddenRGWriter{}, &stderr); code != 1 {
		t.Fatal(code)
	}
	engine, _ := rg.NewEngine(packages)
	handler := httpapi.Handler(engine)
	call := func(method, path, body string, status int) *httptest.ResponseRecorder {
		t.Helper()
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, httptest.NewRequest(method, path, strings.NewReader(body)))
		if w.Code != status {
			t.Fatalf("%s %s: %d %s", method, path, w.Code, w.Body.String())
		}
		if status != 404 && !strings.HasPrefix(w.Header().Get("Content-Type"), "application/json") {
			t.Fatal(w.Header())
		}
		if status >= 400 && status != 404 {
			var m map[string]string
			if e := json.Unmarshal(w.Body.Bytes(), &m); e != nil || m["error"] == "" {
				t.Fatal(w.Body.String(), e)
			}
		}
		return w
	}
	w := call("POST", "/plan", req, 200)
	json.Unmarshal(w.Body.Bytes(), &got)
	want.Revision = 1
	if !reflect.DeepEqual(got, want) {
		t.Fatal(got, want)
	}
	call("POST", "/update", `{"expected":0}`, 409)
	call("POST", "/update", `{"expected":1,"edits":[{"remove":"a"}]}`, 400)
	call("POST", "/plan", `{} {}`, 400)
	call("POST", "/plan", `{"changes":[{"name":"a","level":"bad"}]}`, 400)
	call("GET", "/plan", "", 404)
	call("POST", "/update", `{"expected":1,"edits":[{"remove":"a"},{"remove":"b"}]}`, 200)
	w = call("GET", "/snapshot", "", 200)
	var snap rg.Snapshot
	json.Unmarshal(w.Body.Bytes(), &snap)
	if snap.Revision != 2 || len(snap.Packages) != 0 {
		t.Fatal(snap)
	}
	os.WriteFile(filepath.Join(dir, "bad.json"), []byte("{"), 0600)
	if _, e = catalog.Load(os.DirFS(dir), "."); e == nil {
		t.Fatal("bad JSON")
	}
}
