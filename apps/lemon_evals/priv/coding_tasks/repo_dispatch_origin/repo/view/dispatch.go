package view

import (
    "time"
    "example.com/dispatch/model"
)

type Checkpoint struct {
    Hub string `json:"hub"`
    At string `json:"at"`
}
type Dispatch struct {
    ID string `json:"id"`
    Reference string `json:"reference"`
    Status string `json:"status"`
    Origin *Checkpoint `json:"origin"`
    LatestHub string `json:"latest_hub"`
}
func FromModel(d model.Dispatch) Dispatch {
    v := Dispatch{ID:d.ID, Reference:d.Reference, Status:string(d.Status), LatestHub:d.LatestHub}
    if d.Origin != nil { v.Origin = &Checkpoint{Hub:d.Origin.Hub, At:d.Origin.At.Format(time.RFC3339Nano)} }
    return v
}
