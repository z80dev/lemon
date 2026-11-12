package api

import (
    "net/http"
    "example.com/parcel/service"
    "example.com/parcel/view"
)
func show(desk *service.Desk) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        parcel,err := desk.Show(r.PathValue("id"))
        if err != nil { fail(w,err); return }
        respond(w,200,view.FromModel(parcel))
    }
}
