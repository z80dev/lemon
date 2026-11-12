package releasegraph_test

import (
	rg "arena/releasegraph"
	"arena/releasegraph/adapters/httpapi"
	"net/http/httptest"
	"testing"
)

func TestHTTPSnapshot(t *testing.T) {
	e, _ := rg.NewEngine(nil)
	w := httptest.NewRecorder()
	httpapi.Handler(e).ServeHTTP(w, httptest.NewRequest("GET", "/snapshot", nil))
	if w.Code != 200 {
		t.Fatal(w.Code)
	}
}
