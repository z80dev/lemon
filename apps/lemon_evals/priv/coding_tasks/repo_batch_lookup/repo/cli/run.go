package cli

import (
    "encoding/json"
    "io"
    "example.com/batchdesk/api"
    "example.com/batchdesk/view"
)
func Run(ids []string, service api.Lookup, out io.Writer) error {
    results,err := service.Run(ids)
    if err != nil { return err }
    return json.NewEncoder(out).Encode(view.FromResults(results))
}
