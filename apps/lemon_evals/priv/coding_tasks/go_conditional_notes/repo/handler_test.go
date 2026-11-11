package notes

import (
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCreateAndRead(t *testing.T) {
	h := NewHandler()
	r := httptest.NewRequest("PUT", "/notes/hello", strings.NewReader(`{"text":"world"}`))
	r.Header.Set("If-None-Match", "*")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 201 {
		t.Fatalf("%d %s", w.Code, w.Body.String())
	}
	w = httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/notes/hello", nil))
	if w.Code != 200 || !strings.Contains(w.Body.String(), "world") {
		t.Fatal(w.Code, w.Body.String())
	}
}
