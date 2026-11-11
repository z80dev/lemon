package view

import "example.com/parcel/model"

type Parcel struct {
    ID string `json:"id"`
    Destination string `json:"destination"`
    State string `json:"state"`
    Revision int64 `json:"revision"`
}
func FromModel(p model.Parcel) Parcel {
    return Parcel{ID:p.ID,Destination:p.Destination,State:string(p.State),Revision:p.Revision}
}
