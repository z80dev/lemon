package api

import "net/http"

func Router(service Lookup) http.Handler {
    mux := http.NewServeMux()
    mux.HandleFunc("GET /health",health)
    mux.HandleFunc("POST /v1/orders/lookup",lookup(service))
    return mux
}
