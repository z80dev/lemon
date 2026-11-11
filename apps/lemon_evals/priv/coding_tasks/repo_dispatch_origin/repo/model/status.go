package model

type Status string
const (
    InTransit Status = "in_transit"
    Delivered Status = "delivered"
)
func (s Status) Terminal() bool { return s == Delivered }
