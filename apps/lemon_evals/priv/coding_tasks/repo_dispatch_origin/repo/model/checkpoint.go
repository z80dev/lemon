package model

import "time"

type Checkpoint struct {
    Hub string
    At time.Time
}
func (c Checkpoint) Equal(other Checkpoint) bool {
    return c.Hub == other.Hub && c.At.Equal(other.At)
}
