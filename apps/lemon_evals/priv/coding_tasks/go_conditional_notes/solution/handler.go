package notes

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
)

type note struct {
	Key     string `json:"key"`
	Text    string `json:"text"`
	Version uint64 `json:"version"`
}
type state struct {
	version uint64
	value   *note
}
type handler struct {
	mu    sync.Mutex
	items map[string]state
}

func NewHandler() http.Handler  { return &handler{items: map[string]state{}} }
func tag(version uint64) string { return "\"" + strconv.FormatUint(version, 10) + "\"" }
func validKey(key string) bool {
	if len(key) < 1 || len(key) > 32 || key[0] < 'a' || key[0] > 'z' {
		return false
	}
	for _, c := range []byte(key[1:]) {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}
func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
func fail(w http.ResponseWriter, status int) {
	writeJSON(w, status, map[string]string{"error": http.StatusText(status)})
}
func parseTag(text string) (uint64, bool) {
	if len(text) < 3 || text[0] != '"' || text[len(text)-1] != '"' {
		return 0, false
	}
	digits := text[1 : len(text)-1]
	n, e := strconv.ParseUint(digits, 10, 64)
	return n, e == nil && n > 0 && strconv.FormatUint(n, 10) == digits
}
func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !strings.HasPrefix(r.URL.Path, "/notes/") {
		fail(w, 404)
		return
	}
	key := strings.TrimPrefix(r.URL.Path, "/notes/")
	if !validKey(key) {
		fail(w, 404)
		return
	}
	switch r.Method {
	case "GET":
		h.get(w, r, key)
	case "PUT", "DELETE":
		h.change(w, r, key)
	default:
		w.Header().Set("Allow", "GET, PUT, DELETE")
		fail(w, 405)
	}
}
func (h *handler) get(w http.ResponseWriter, r *http.Request, key string) {
	h.mu.Lock()
	current := h.items[key].value
	var value note
	if current != nil {
		value = *current
	}
	h.mu.Unlock()
	if current == nil {
		fail(w, 404)
		return
	}
	etag := tag(value.Version)
	w.Header().Set("ETag", etag)
	if r.Header.Get("If-None-Match") == etag {
		w.WriteHeader(304)
		return
	}
	writeJSON(w, 200, value)
}
func (h *handler) change(w http.ResponseWriter, r *http.Request, key string) {
	match, none := r.Header.Get("If-Match"), r.Header.Get("If-None-Match")
	create := false
	var version uint64
	if match == "" && none == "" {
		fail(w, 428)
		return
	}
	if none != "" {
		if r.Method != "PUT" || none != "*" || match != "" {
			fail(w, 400)
			return
		}
		create = true
	} else {
		var ok bool
		version, ok = parseTag(match)
		if !ok {
			fail(w, 400)
			return
		}
	}
	var text string
	if r.Method == "PUT" {
		data, err := io.ReadAll(io.LimitReader(r.Body, 16385))
		if len(data) > 16384 {
			fail(w, 413)
			return
		}
		if err != nil {
			fail(w, 400)
			return
		}
		dec := json.NewDecoder(bytes.NewReader(data))
		opening, err := dec.Token()
		if err != nil || opening != json.Delim('{') {
			fail(w, 400)
			return
		}
		field, err := dec.Token()
		if err != nil || field != "text" {
			fail(w, 400)
			return
		}
		var value *string
		if err := dec.Decode(&value); err != nil || value == nil {
			fail(w, 400)
			return
		}
		closing, err := dec.Token()
		if err != nil || closing != json.Delim('}') {
			fail(w, 400)
			return
		}
		var extra any
		if err := dec.Decode(&extra); err != io.EOF {
			fail(w, 400)
			return
		}
		text = *value
		if len(text) > 4096 {
			fail(w, 400)
			return
		}
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	current := h.items[key]
	if create {
		if current.value != nil {
			fail(w, 412)
			return
		}
	} else {
		if current.value == nil || current.version != version {
			fail(w, 412)
			return
		}
	}
	if r.Method == "DELETE" {
		current.value = nil
		h.items[key] = current
		w.WriteHeader(204)
		return
	}
	current.version++
	value := note{key, text, current.version}
	current.value = &value
	h.items[key] = current
	w.Header().Set("ETag", tag(value.Version))
	status := 200
	if create {
		status = 201
	}
	writeJSON(w, status, value)
}
