package notes

import (
	"net/http/httptest"
	"strings"
	"testing"
)

func TestMissingPrecondition(t *testing.T) {
	h := NewHandler()
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("PUT", "/notes/a", strings.NewReader(`{"text":"x"}`)))
	if w.Code != 428 {
		t.Fatal(w.Code)
	}
}
