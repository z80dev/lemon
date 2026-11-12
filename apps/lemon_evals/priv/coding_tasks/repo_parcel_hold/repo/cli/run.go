package cli

import (
    "errors"
    "io"
    "example.com/parcel/service"
)
func Run(args []string, desk *service.Desk, out io.Writer) error {
    if len(args) != 2 || args[0] != "show" { return errors.New("usage: parcel show ID") }
    parcel,err := desk.Show(args[1])
    if err != nil { return err }
    return output(out,parcel)
}
