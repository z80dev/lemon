package api

import (
    "errors"
    "net/http"
    "example.com/parcel/model"
)
func fail(w http.ResponseWriter, err error) {
    status,message := 500,"internal error"
    if errors.Is(err,model.ErrNotFound) { status,message=404,model.ErrNotFound.Error() }
    respond(w,status,map[string]string{"error":message})
}
