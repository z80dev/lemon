package storage

import "example.com/parcel/model"

type record struct {
    ID string `json:"id"`
    Destination string `json:"destination"`
    State string `json:"state"`
    Revision int64 `json:"revision"`
    HoldReason *string `json:"hold_reason,omitempty"`
}
func toRecord(p model.Parcel) record {
    row := record{ID:p.ID,Destination:p.Destination,State:string(p.State),Revision:p.Revision}
    if p.Hold != nil { reason := p.Hold.Reason; row.HoldReason = &reason }
    return row
}
func fromRecord(r record) model.Parcel {
    p := model.Parcel{ID:r.ID,Destination:r.Destination,State:model.State(r.State),Revision:r.Revision}
    if r.HoldReason != nil { p.Hold = &model.Hold{Reason:*r.HoldReason} }
    return p
}
