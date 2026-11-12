package releasegraph_test

import (
	rg "arena/releasegraph"
	"bytes"
	"testing"
)

func TestEmptyReport(t *testing.T) {
	var b bytes.Buffer
	if e := rg.WriteReport(&b, rg.Plan{}); e != nil || b.Len() != 0 {
		t.Fatal(e)
	}
}
