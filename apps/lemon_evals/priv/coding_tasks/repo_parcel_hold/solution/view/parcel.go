package view

import "example.com/parcel/model"

type Hold struct { Reason string `json:"reason"` }
type Parcel struct {
    ID string `json:"id"`
    Destination string `json:"destination"`
    State string `json:"state"`
    Revision int64 `json:"revision"`
    Hold *Hold `json:"hold"`
}
func FromModel(p model.Parcel) Parcel {
    value := Parcel{ID:p.ID,Destination:p.Destination,State:string(p.State),Revision:p.Revision}
    if p.Hold != nil { value.Hold = &Hold{Reason:p.Hold.Reason} }
    return value
}
