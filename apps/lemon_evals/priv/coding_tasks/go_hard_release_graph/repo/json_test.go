package releasegraph_test

import (
	"arena/releasegraph/adapters/jsonapi"
	"strings"
	"testing"
)

func TestDecodeRequest(t *testing.T) {
	r, e := jsonapi.ReadRequest(strings.NewReader(`{"changes":[{"name":"core","level":"patch"}]}`))
	if e != nil || len(r.Changes) != 1 {
		t.Fatal(e)
	}
}
