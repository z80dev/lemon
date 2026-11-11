package model

type State string
const (
    Ready State = "ready"
    Delivered State = "delivered"
)
func (s State) Terminal() bool { return s == Delivered }
