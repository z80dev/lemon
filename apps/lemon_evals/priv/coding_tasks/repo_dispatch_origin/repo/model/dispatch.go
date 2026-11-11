package model

type Dispatch struct {
    ID string
    Reference string
    Status Status
    Origin *Checkpoint
    LatestHub string
}
