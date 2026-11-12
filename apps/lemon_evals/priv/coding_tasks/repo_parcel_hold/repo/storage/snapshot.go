package storage

import (
    "encoding/json"
    "os"
)
type snapshot struct { Records map[string]record `json:"records"` }
func load(path string) (map[string]record,error) {
    data,err := os.ReadFile(path)
    if os.IsNotExist(err) { return make(map[string]record),nil }
    if err != nil { return nil,err }
    var state snapshot
    if err := json.Unmarshal(data,&state); err != nil { return nil,err }
    if state.Records == nil { state.Records = make(map[string]record) }
    return state.Records,nil
}
