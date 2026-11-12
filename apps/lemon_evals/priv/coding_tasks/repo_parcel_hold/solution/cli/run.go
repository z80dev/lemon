package cli

import (
    "errors"
    "io"
    "example.com/parcel/model"
    "example.com/parcel/service"
)
func Run(args []string, desk *service.Desk, out io.Writer) error {
    usage := errors.New("usage: parcel show ID | hold ID REASON | release ID")
    if len(args) == 0 { return usage }
    var parcel model.Parcel
    var err error
    switch args[0] {
    case "show":
        if len(args) != 2 { return usage }
        parcel,err = desk.Show(args[1])
    case "hold":
        if len(args) != 3 { return usage }
        parcel,err = desk.PlaceHold(args[1],args[2])
    case "release":
        if len(args) != 2 { return usage }
        parcel,err = desk.ReleaseHold(args[1])
    default: return usage
    }
    if err != nil { return err }
    return output(out,parcel)
}
