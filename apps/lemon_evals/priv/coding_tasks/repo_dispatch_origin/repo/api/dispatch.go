package api

import (
    "net/http"
    "example.com/dispatch/model"
    "example.com/dispatch/view"
)

type Lookup interface { Lookup(account, id string) (model.Dispatch, error) }
type DispatchHandler struct { tracker Lookup }
func NewDispatchHandler(tracker Lookup) *DispatchHandler { return &DispatchHandler{tracker:tracker} }
func (h *DispatchHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
    dispatch, err := h.tracker.Lookup(r.Header.Get("X-Account"),r.PathValue("id"))
    if err != nil { writeError(w,err); return }
    jsonResponse(w,http.StatusOK,view.FromModel(dispatch))
}
