package notes

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

func arenaHiddenRequest(h http.Handler, method, path, body string, headers map[string]string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	for k, v := range headers {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}
func arenaHiddenCheck(t *testing.T, w *httptest.ResponseRecorder, status int) {
	t.Helper()
	if w.Code != status {
		t.Fatalf("status %d want %d: %s", w.Code, status, w.Body.String())
	}
	if status == 204 || status == 304 {
		if w.Body.Len() != 0 {
			t.Fatal("body must be empty")
		}
		return
	}
	if w.Header().Get("Content-Type") != "application/json" {
		t.Fatalf("JSON content type: %q", w.Header().Get("Content-Type"))
	}
	if status >= 400 {
		var body map[string]any
		if json.Unmarshal(w.Body.Bytes(), &body) != nil {
			t.Fatal("non-JSON error")
		}
		if text, ok := body["error"].(string); !ok || text == "" {
			t.Fatal("missing error field")
		}
	}
}
func arenaHiddenRepresentation(t *testing.T, w *httptest.ResponseRecorder, key, text string, version int) {
	t.Helper()
	var got map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 || got["key"] != key || got["text"] != text || got["version"] != float64(version) || w.Header().Get("ETag") != fmt.Sprintf("\"%d\"", version) {
		t.Fatalf("arenaHiddenRepresentation %v %q", got, w.Header().Get("ETag"))
	}
}
func TestArenaHiddenNotesLifecycle(t *testing.T) {
	h := NewHandler()
	create := map[string]string{"If-None-Match": "*"}
	one := map[string]string{"If-Match": "\"1\""}
	arenaHiddenCheck(t, arenaHiddenRequest(h, "GET", "/notes/a", "", nil), 404)
	w := arenaHiddenRequest(h, "PUT", "/notes/a", `{"text":"line\n☃"}`, create)
	arenaHiddenCheck(t, w, 201)
	arenaHiddenRepresentation(t, w, "a", "line\n☃", 1)
	arenaHiddenCheck(t, arenaHiddenRequest(h, "PUT", "/notes/a", `{"text":"other"}`, create), 412)
	w = arenaHiddenRequest(h, "GET", "/notes/a", "", map[string]string{"If-None-Match": "\"1\""})
	arenaHiddenCheck(t, w, 304)
	if w.Header().Get("ETag") != "\"1\"" {
		t.Fatal("304 tag")
	}
	w = arenaHiddenRequest(h, "GET", "/notes/a", "", map[string]string{"If-None-Match": "*"})
	arenaHiddenCheck(t, w, 200)
	arenaHiddenRepresentation(t, w, "a", "line\n☃", 1)
	w = arenaHiddenRequest(h, "PUT", "/notes/a", `{"text":""}`, one)
	arenaHiddenCheck(t, w, 200)
	arenaHiddenRepresentation(t, w, "a", "", 2)
	arenaHiddenCheck(t, arenaHiddenRequest(h, "DELETE", "/notes/a", "ignored", one), 412)
	arenaHiddenCheck(t, arenaHiddenRequest(h, "DELETE", "/notes/a", "ignored", map[string]string{"If-Match": "\"2\""}), 204)
	arenaHiddenCheck(t, arenaHiddenRequest(h, "GET", "/notes/a", "", nil), 404)
	arenaHiddenCheck(t, arenaHiddenRequest(h, "DELETE", "/notes/a", "", map[string]string{"If-Match": "\"2\""}), 412)
	w = arenaHiddenRequest(h, "PUT", "/notes/a", `{"text":"reborn"}`, create)
	arenaHiddenCheck(t, w, 201)
	arenaHiddenRepresentation(t, w, "a", "reborn", 3)
	arenaHiddenCheck(t, arenaHiddenRequest(h, "PUT", "/notes/a", `{"text":"stale"}`, one), 412)
	arenaHiddenCheck(t, arenaHiddenRequest(NewHandler(), "GET", "/notes/a", "", nil), 404)
}
func TestArenaHiddenValidation(t *testing.T) {
	h := NewHandler()
	create := map[string]string{"If-None-Match": "*"}
	for _, path := range []string{"/", "/notes/", "/notes/A", "/notes/a/b", "/notes/1a", "/notes/" + strings.Repeat("a", 33), "/else/a"} {
		arenaHiddenCheck(t, arenaHiddenRequest(h, "GET", path, "", nil), 404)
	}
	w := arenaHiddenRequest(h, "POST", "/notes/a", "", nil)
	arenaHiddenCheck(t, w, 405)
	if w.Header().Get("Allow") != "GET, PUT, DELETE" {
		t.Fatal("Allow")
	}
	for _, method := range []string{"PUT", "DELETE"} {
		arenaHiddenCheck(t, arenaHiddenRequest(h, method, "/notes/a", "bad", nil), 428)
	}
	for _, headers := range []map[string]string{{"If-Match": "1"}, {"If-Match": "\"01\""}, {"If-Match": "\"0\""}, {"If-Match": "\"+1\""}, {"If-Match": "W/\"1\""}, {"If-Match": "\"1\", \"2\""}, {"If-Match": "\"18446744073709551616\""}, {"If-None-Match": "x"}, {"If-Match": "\"1\"", "If-None-Match": "*"}} {
		arenaHiddenCheck(t, arenaHiddenRequest(h, "PUT", "/notes/a", `{"text":"x"}`, headers), 400)
	}
	arenaHiddenCheck(t, arenaHiddenRequest(h, "DELETE", "/notes/a", "", create), 400)
	for _, body := range []string{"", "null", "[]", "{}", `{"text":null}`, `{"text":7}`, `{"TEXT":"x"}`, `{"text":"x","text":"y"}`, `{"text":"x","extra":1}`, `{"text":"x"} {}`, `{"text":"x"} trailing`, `{"text":"` + strings.Repeat("x", 4097) + `"}`} {
		arenaHiddenCheck(t, arenaHiddenRequest(h, "PUT", "/notes/a", body, create), 400)
		arenaHiddenCheck(t, arenaHiddenRequest(h, "GET", "/notes/a", "", nil), 404)
	}
	arenaHiddenCheck(t, arenaHiddenRequest(h, "PUT", "/notes/a", `{"text":"x"}`+strings.Repeat(" ", 16384), create), 413)
	exact := `{"text":"` + strings.Repeat("x", 4096) + `"}`
	w = arenaHiddenRequest(h, "PUT", "/notes/max", exact, create)
	arenaHiddenCheck(t, w, 201)
	// Body validation occurs before the existence/version arenaHiddenCheck.
	arenaHiddenCheck(t, arenaHiddenRequest(h, "PUT", "/notes/missing", `{}`, map[string]string{"If-Match": "\"1\""}), 400)
	arenaHiddenCheck(t, arenaHiddenRequest(h, "PUT", "/notes/missing", `{"text":"x"}`, map[string]string{"If-Match": "\"1\""}), 412)
	r := httptest.NewRequest("PUT", "/notes/readfail", nil)
	r.Body = io.NopCloser(arenaHiddenFailing{})
	r.Header.Set("If-None-Match", "*")
	w = httptest.NewRecorder()
	h.ServeHTTP(w, r)
	arenaHiddenCheck(t, w, 400)
}

type arenaHiddenFailing struct{}

func (arenaHiddenFailing) Read([]byte) (int, error) { return 0, errors.New("body failed") }
func TestArenaHiddenConcurrentCompareAndSwap(t *testing.T) {
	h := NewHandler()
	arenaHiddenCheck(t, arenaHiddenRequest(h, "PUT", "/notes/shared", `{"text":"initial"}`, map[string]string{"If-None-Match": "*"}), 201)
	const workers = 48
	codes := make(chan int, workers)
	var wg sync.WaitGroup
	for n := 0; n < workers; n++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			w := arenaHiddenRequest(h, "PUT", "/notes/shared", fmt.Sprintf(`{"text":"writer-%d"}`, n), map[string]string{"If-Match": "\"1\""})
			codes <- w.Code
			_ = arenaHiddenRequest(h, "GET", "/notes/shared", "", nil)
		}(n)
	}
	wg.Wait()
	close(codes)
	wins := 0
	for code := range codes {
		switch code {
		case 200:
			wins++
		case 412:
		default:
			t.Fatalf("unexpected %d", code)
		}
	}
	if wins != 1 {
		t.Fatalf("winners %d", wins)
	}
	w := arenaHiddenRequest(h, "GET", "/notes/shared", "", nil)
	arenaHiddenCheck(t, w, 200)
	if w.Header().Get("ETag") != "\"2\"" {
		t.Fatal("version not atomic")
	}
}
