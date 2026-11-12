package ledger_test

import (
	"arena/ledger/app"
	"bytes"
	"strings"
	"testing"
)

func TestUsage(t *testing.T) {
	var out, err bytes.Buffer
	if code := app.Run(nil, strings.NewReader(""), &out, &err); code != 2 || out.Len() != 0 || err.Len() == 0 {
		t.Fatal(code)
	}
}
