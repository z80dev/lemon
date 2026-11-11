package storage

import "example.com/parcel/model"

type record struct {
    ID string `json:"id"`
    Destination string `json:"destination"`
    State string `json:"state"`
    Revision int64 `json:"revision"`
}
func toRecord(p model.Parcel) record {
    return record{ID:p.ID,Destination:p.Destination,State:string(p.State),Revision:p.Revision}
}
func fromRecord(r record) model.Parcel {
    return model.Parcel{ID:r.ID,Destination:r.Destination,State:model.State(r.State),Revision:r.Revision}
}
