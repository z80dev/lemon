package model

type Hold struct { Reason string }
type Parcel struct {
    ID string
    Destination string
    State State
    Revision int64
    Hold *Hold
}
