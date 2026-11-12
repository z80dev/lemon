package httpapi

import (
	rg "arena/releasegraph"
	"arena/releasegraph/adapters/jsonapi"
	"encoding/json"
	"errors"
	"net/http"
)

func Handler(e *rg.Engine) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fail := func(err error) {
			status := http.StatusBadRequest
			if errors.Is(err, rg.ErrConflict) {
				status = http.StatusConflict
			}
			w.WriteHeader(status)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		}
		switch {
		case r.Method == "GET" && r.URL.Path == "/snapshot":
			_ = jsonapi.WriteSnapshot(w, e.Snapshot())
		case r.Method == "POST" && r.URL.Path == "/plan":
			req, err := jsonapi.ReadRequest(r.Body)
			if err != nil {
				fail(err)
				return
			}
			p, err := e.Plan(req)
			if err != nil {
				fail(err)
				return
			}
			_ = jsonapi.WritePlan(w, p)
		case r.Method == "POST" && r.URL.Path == "/update":
			u, err := jsonapi.ReadUpdate(r.Body)
			if err != nil {
				fail(err)
				return
			}
			s, err := e.Apply(u)
			if err != nil {
				fail(err)
				return
			}
			_ = jsonapi.WriteSnapshot(w, s)
		default:
			http.NotFound(w, r)
		}
	})
}
