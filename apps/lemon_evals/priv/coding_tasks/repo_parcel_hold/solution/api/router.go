package api

import (
    "net/http"
    "example.com/parcel/service"
)
func Router(desk *service.Desk) http.Handler {
    mux := http.NewServeMux()
    mux.HandleFunc("GET /v1/parcels/{id}",show(desk))
    mux.HandleFunc("POST /v1/parcels/{id}/hold",placeHold(desk))
    mux.HandleFunc("DELETE /v1/parcels/{id}/hold",releaseHold(desk))
    return mux
}
