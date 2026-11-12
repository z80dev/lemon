package api

import (
    "encoding/json"
    "net/http"
)
func respond(w http.ResponseWriter,status int,body any) {
    w.Header().Set("Content-Type","application/json")
    w.WriteHeader(status)
    _ = json.NewEncoder(w).Encode(body)
}
