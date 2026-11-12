package app

import (
	"bytes"
	"strings"
	"testing"
)

func TestAggregateBeforeMinimum(t *testing.T) {
	var out, diag bytes.Buffer
	code := Run([]string{"-min", "3"}, strings.NewReader("sku,quantity\nx,2\nx,2\n"), &out, &diag)
	if code != 0 || out.String() != "sku,total\nx,4\n" {
		t.Fatal(code, out.String(), diag.String())
	}
}
