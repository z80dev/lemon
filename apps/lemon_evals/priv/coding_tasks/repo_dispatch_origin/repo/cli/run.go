package cli

import (
    "encoding/json"
    "fmt"
    "io"
    "example.com/dispatch/api"
    "example.com/dispatch/view"
)
func Run(args []string, tracker api.Lookup, out io.Writer) error {
    if len(args) != 2 { return fmt.Errorf("usage: dispatch ACCOUNT ID") }
    value, err := tracker.Lookup(args[0],args[1])
    if err != nil { return err }
    return json.NewEncoder(out).Encode(view.FromModel(value))
}
