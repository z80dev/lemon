package api

import (
    "errors"
    "net/http"
    "example.com/dispatch/model"
)
func writeError(w http.ResponseWriter, err error) {
    status, message := http.StatusInternalServerError, "internal error"
    if errors.Is(err,model.ErrNotFound) { status,message = http.StatusNotFound,model.ErrNotFound.Error() }
    if errors.Is(err,model.ErrAccountRequired) { status,message = http.StatusUnauthorized,model.ErrAccountRequired.Error() }
    jsonResponse(w,status,map[string]string{"error":message})
}
