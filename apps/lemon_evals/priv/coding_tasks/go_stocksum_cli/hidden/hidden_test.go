package app

import (
	"bytes"
	"errors"
	"io"
	"os/exec"
	"strings"
	"testing"
)

type brokenReader struct{}

func (brokenReader) Read([]byte) (int, error) { return 0, errors.New("read failed") }

type brokenWriter struct{}

func (brokenWriter) Write([]byte) (int, error) { return 0, errors.New("write failed") }
func TestCLIContract(t *testing.T) {
	cases := []struct {
		args       []string
		text, want string
		code       int
	}{
		{nil, "sku,quantity\nz,2\na,4\nz,-1\nb,-2\n", "sku,total\na,4\nz,1\n", 0},
		{[]string{"-min=-3"}, "sku,quantity\n b , -2 \na,0\n", "sku,total\na,0\nb,-2\n", 0},
		{[]string{"-sku", "z", "-min", "2"}, "sku,quantity\nz,1\nz,1\na,99\n", "sku,total\nz,2\n", 0},
		{nil, "sku,quantity\n\"a,b\",3\n", "sku,total\n\"a,b\",3\n", 0},
		{nil, "sku,quantity\n", "sku,total\n", 0},
		{nil, "sku,quantity\nA,1\nB,no\n", "", 1},
		{nil, "", "", 1}, {nil, "SKU,quantity\nA,1\n", "", 1}, {nil, "sku,quantity\n,2\n", "", 1},
		{nil, "sku,quantity\nA,9223372036854775808\n", "", 1}, {nil, "sku,quantity\nA,2,3\n", "", 1},
		{[]string{"-min", "oops"}, "", "", 2}, {[]string{"-wat"}, "", "", 2}, {[]string{"extra"}, "", "", 2},
		{[]string{"-h"}, "", "", 0}, {[]string{"-help"}, "", "", 0},
	}
	for _, c := range cases {
		var out, diag bytes.Buffer
		code := Run(c.args, strings.NewReader(c.text), &out, &diag)
		if code != c.code || out.String() != c.want {
			t.Fatalf("%v %q: code=%d stdout=%q stderr=%q", c.args, c.text, code, out.String(), diag.String())
		}
		if (code != 0 || len(c.args) > 0 && strings.HasPrefix(c.args[0], "-h")) && diag.Len() == 0 {
			t.Fatal("missing diagnostic")
		}
	}
	var out, diag bytes.Buffer
	if Run(nil, io.MultiReader(strings.NewReader("sku,quantity\n"), brokenReader{}), &out, &diag) != 1 || out.Len() != 0 {
		t.Fatal("read error")
	}
	diag.Reset()
	if Run(nil, strings.NewReader("sku,quantity\nA,2\n"), brokenWriter{}, &diag) != 1 || diag.Len() == 0 {
		t.Fatal("write error")
	}
	cmd := exec.Command("go", "build", "-o", t.TempDir()+"/stocksum", "../cmd/stocksum")
	if data, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("build: %s %v", data, err)
	}
	binary := cmd.Args[3]
	p := exec.Command(binary, "-unknown")
	err := p.Run()
	var ee *exec.ExitError
	if !errors.As(err, &ee) || ee.ExitCode() != 2 {
		t.Fatalf("main exit %v", err)
	}
}
