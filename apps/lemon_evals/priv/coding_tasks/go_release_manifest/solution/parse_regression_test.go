package manifest

import (
	"strings"
	"testing"
)

func TestEscapedQuotedValue(t *testing.T) {
	got, err := Parse(strings.NewReader(`note="line\nnext" # note`))
	if err != nil || len(got) != 1 || got[0].Value != "line\nnext" {
		t.Fatal(got, err)
	}
}
