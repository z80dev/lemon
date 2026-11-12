package api

import "net/http"

func Router(tracker Lookup) http.Handler {
    mux := http.NewServeMux()
    mux.Handle("GET /v1/dispatches/{id}",NewDispatchHandler(tracker))
    return mux
}
