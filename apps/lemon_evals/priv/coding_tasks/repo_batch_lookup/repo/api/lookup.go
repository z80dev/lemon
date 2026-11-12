package api

import (
    "net/http"
    "example.com/batchdesk/model"
    "example.com/batchdesk/view"
)
type Lookup interface { Run(ids []string) ([]model.Result,error) }
func lookup(service Lookup) http.HandlerFunc {
    return func(w http.ResponseWriter,r *http.Request) {
        body,err := decode(r.Body)
        if err != nil { respond(w,400,map[string]string{"error":"invalid request"}); return }
        results,err := service.Run(body.IDs)
        if err != nil { respond(w,500,map[string]string{"error":"lookup failed"}); return }
        respond(w,200,view.FromResults(results))
    }
}
