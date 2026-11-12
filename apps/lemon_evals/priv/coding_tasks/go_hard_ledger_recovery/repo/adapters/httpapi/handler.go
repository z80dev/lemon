package httpapi

import (
	l "arena/ledger"
	"arena/ledger/adapters/jsonapi"
	"encoding/json"
	"errors"
	"net/http"
)

func Handler(engine *l.Engine) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fail := func(err error) {
			code := 400
			if errors.Is(err, l.ErrConflict) {
				code = 409
			}
			w.WriteHeader(code)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		}
		switch {
		case r.Method == "GET" && r.URL.Path == "/snapshot":
			_ = jsonapi.WriteSnapshot(w, engine.Snapshot())
		case r.Method == "GET" && r.URL.Path == "/report":
			report, err := l.Summarize(l.Result{State: engine.Snapshot()})
			if err != nil {
				fail(err)
				return
			}
			_ = jsonapi.WriteSummary(w, report)
		case r.Method == "POST" && r.URL.Path == "/recover":
			req, err := jsonapi.ReadRecovery(r.Body)
			if err != nil {
				fail(err)
				return
			}
			out, err := engine.Recover(req.Expected, req.Journal)
			if err != nil {
				fail(err)
				return
			}
			_ = jsonapi.WriteResult(w, out)
		default:
			http.NotFound(w, r)
		}
	})
}
