package api

import (
    "encoding/json"
    "errors"
    "io"
    "net/http"
    "example.com/parcel/service"
    "example.com/parcel/view"
)
func readReason(r *http.Request) (string,error) {
    var fields map[string]json.RawMessage
    decoder := json.NewDecoder(r.Body)
    if err := decoder.Decode(&fields); err != nil { return "",err }
    if fields == nil { return "",errors.New("object required") }
    var extra any
    if err := decoder.Decode(&extra); err != io.EOF { return "",errors.New("trailing JSON") }
    for name := range fields { if name != "reason" { return "",errors.New("unknown field") } }
    value,ok := fields["reason"]
    if !ok { return "",nil }
    var reason *string
    if err := json.Unmarshal(value,&reason); err != nil { return "",err }
    if reason == nil { return "",errors.New("reason must be a string") }
    return *reason,nil
}
func placeHold(desk *service.Desk) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        reason,err := readReason(r)
        if err != nil { respond(w,400,map[string]string{"error":"invalid request"}); return }
        parcel,err := desk.PlaceHold(r.PathValue("id"),reason)
        if err != nil { fail(w,err); return }
        respond(w,200,view.FromModel(parcel))
    }
}
func releaseHold(desk *service.Desk) http.HandlerFunc {
    return func(w http.ResponseWriter, r *http.Request) {
        parcel,err := desk.ReleaseHold(r.PathValue("id"))
        if err != nil { fail(w,err); return }
        respond(w,200,view.FromModel(parcel))
    }
}
