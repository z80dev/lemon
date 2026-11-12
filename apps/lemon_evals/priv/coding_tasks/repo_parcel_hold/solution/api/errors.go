package api

import (
    "errors"
    "net/http"
    "example.com/parcel/model"
)
func fail(w http.ResponseWriter, err error) {
    status,message := 500,"internal error"
    switch {
    case errors.Is(err,model.ErrNotFound): status,message=404,model.ErrNotFound.Error()
    case errors.Is(err,model.ErrInvalidReason): status,message=400,model.ErrInvalidReason.Error()
    case errors.Is(err,model.ErrDelivered): status,message=409,model.ErrDelivered.Error()
    case errors.Is(err,model.ErrAlreadyHeld): status,message=409,model.ErrAlreadyHeld.Error()
    }
    respond(w,status,map[string]string{"error":message})
}
