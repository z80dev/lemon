package releasegraph_test

import (
	"arena/releasegraph/app"
	"bytes"
	"strings"
	"testing"
)

func TestUsage(t *testing.T) {
	var out, err bytes.Buffer
	if app.Run(nil, strings.NewReader(""), &out, &err) != 2 || out.Len() != 0 || err.Len() == 0 {
		t.Fatal("usage")
	}
}
