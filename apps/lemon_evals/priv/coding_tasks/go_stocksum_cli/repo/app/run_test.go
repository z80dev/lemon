package app

import (
	"bytes"
	"strings"
	"testing"
)

func TestSingle(t *testing.T) {
	var out, diag bytes.Buffer
	code := Run(nil, strings.NewReader("sku,quantity\nA,2\n"), &out, &diag)
	if code != 0 || out.String() != "sku,total\nA,2\n" {
		t.Fatalf("%d %q %q", code, out.String(), diag.String())
	}
}
