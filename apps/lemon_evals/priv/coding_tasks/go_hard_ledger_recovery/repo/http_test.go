package ledger_test

import (
	l "arena/ledger"
	"arena/ledger/adapters/httpapi"
	"net/http/httptest"
	"testing"
)

func TestSnapshotHTTP(t *testing.T) {
	s, _ := l.NewSnapshot(nil)
	e, _ := l.NewEngine(s)
	w := httptest.NewRecorder()
	httpapi.Handler(e).ServeHTTP(w, httptest.NewRequest("GET", "/snapshot", nil))
	if w.Code != 200 {
		t.Fatal(w.Code)
	}
}
