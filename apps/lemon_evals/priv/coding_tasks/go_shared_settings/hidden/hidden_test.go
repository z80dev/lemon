package settings_test

import (
	"errors"
	"example.com/go_shared_settings/batch"
	"example.com/go_shared_settings/internal/config"
	"example.com/go_shared_settings/server"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestSharedBehavior(t *testing.T) {
	for _, load := range []func(string) (config.Settings, error){config.Parse, batch.Load, server.Load} {
		for _, c := range []struct {
			text string
			want config.Settings
		}{{"", config.Settings{Workers: 4, Timeout: 5 * time.Second}}, {" # hi\r\n workers = 64 \n timeout = 1500ms ", config.Settings{Workers: 64, Timeout: 1500 * time.Millisecond}}, {"workers=+1", config.Settings{Workers: 1, Timeout: 5 * time.Second}}} {
			got, err := load(c.text)
			if err != nil || !reflect.DeepEqual(got, c.want) {
				t.Fatalf("%q: %v %v", c.text, got, err)
			}
		}
		for _, text := range []string{"workers=0", "workers=65", "workers=-2", "workers=1.5", "timeout=0", "timeout=-1s", "timeout=bad", "unknown=1", "workers=2\nworkers=3", "timeout=1s\ntimeout=1s", "workers", "workers=2 # comment"} {
			got, err := load(text)
			if got != (config.Settings{}) || !errors.Is(err, config.ErrInvalid) {
				t.Fatalf("accepted %q: %v %v", text, got, err)
			}
		}
	}
	cfg := config.Settings{Workers: 3, Timeout: time.Second}
	if batch.Describe(cfg) != "3 workers / 1s" || !server.Ready(cfg) || server.Ready(config.Settings{}) {
		t.Fatal("callers not migrated")
	}
}
func TestNoDuplicateParsers(t *testing.T) {
	for _, dir := range []string{"batch", "server"} {
		entries, err := os.ReadDir(dir)
		if err != nil {
			t.Fatal(err)
		}
		found := false
		for _, entry := range entries {
			if !strings.HasSuffix(entry.Name(), ".go") || strings.HasSuffix(entry.Name(), "_test.go") {
				continue
			}
			f, err := parser.ParseFile(token.NewFileSet(), filepath.Join(dir, entry.Name()), nil, 0)
			if err != nil {
				t.Fatal(err)
			}
			alias := ""
			for _, im := range f.Imports {
				path, _ := strconv.Unquote(im.Path.Value)
				if path == "example.com/go_shared_settings/internal/config" {
					alias = "config"
					if im.Name != nil {
						alias = im.Name.Name
					}
				}
			}
			for _, decl := range f.Decls {
				switch d := decl.(type) {
				case *ast.GenDecl:
					for _, spec := range d.Specs {
						if typ, ok := spec.(*ast.TypeSpec); ok && typ.Name.Name == "Settings" {
							t.Fatal("obsolete local Settings")
						}
					}
				case *ast.FuncDecl:
					if d.Name.Name == "parse" {
						t.Fatal("obsolete parse helper")
					}
					if d.Name.Name != "Load" {
						continue
					}
					found = true
					if d.Body == nil || len(d.Body.List) != 1 {
						t.Fatal("Load must directly delegate")
					}
					ret, ok := d.Body.List[0].(*ast.ReturnStmt)
					if !ok || len(ret.Results) != 1 {
						t.Fatal("Load must return Parse call")
					}
					call, ok := ret.Results[0].(*ast.CallExpr)
					if !ok {
						t.Fatal("Load must call Parse")
					}
					sel, ok := call.Fun.(*ast.SelectorExpr)
					if !ok || sel.Sel.Name != "Parse" {
						t.Fatal("Load must call shared Parse")
					}
					name, ok := sel.X.(*ast.Ident)
					if !ok || alias == "" || name.Name != alias {
						t.Fatal("Load uses wrong parser")
					}
				}
			}
		}
		if !found {
			t.Fatal("missing Load")
		}
	}
}
