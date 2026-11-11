package api

import (
    "encoding/json"
    "errors"
    "io"
)
type request struct { IDs []string `json:"ids"` }
func decode(in io.Reader) (request,error) {
    var body request
    decoder := json.NewDecoder(in)
    decoder.DisallowUnknownFields()
    if err := decoder.Decode(&body); err != nil { return body,err }
    var extra any
    if err := decoder.Decode(&extra); err != io.EOF { return body,errors.New("trailing body") }
    return body,nil
}
