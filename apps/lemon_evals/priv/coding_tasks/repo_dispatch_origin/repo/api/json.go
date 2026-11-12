package api

import (
    "encoding/json"
    "net/http"
)
func jsonResponse(w http.ResponseWriter, status int, value any) {
    w.Header().Set("Content-Type","application/json")
    w.WriteHeader(status)
    _ = json.NewEncoder(w).Encode(value)
}
