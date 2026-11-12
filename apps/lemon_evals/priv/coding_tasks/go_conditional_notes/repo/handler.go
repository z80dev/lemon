package notes

import (
	"encoding/json"
	"net/http"
	"strings"
)

type note struct {
	Key     string `json:"key"`
	Text    string `json:"text"`
	Version uint64 `json:"version"`
}
type handler struct{ items map[string]note }

func NewHandler() http.Handler { return &handler{items: map[string]note{}} }
func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	key := strings.TrimPrefix(r.URL.Path, "/notes/")
	switch r.Method {
	case "PUT":
		var body struct {
			Text string `json:"text"`
		}
		if json.NewDecoder(r.Body).Decode(&body) != nil {
			http.Error(w, "bad body", 400)
			return
		}
		n := note{key, body.Text, 1}
		h.items[key] = n
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(201)
		json.NewEncoder(w).Encode(n)
	case "GET":
		n, ok := h.items[key]
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(n)
	default:
		w.WriteHeader(405)
	}
}
