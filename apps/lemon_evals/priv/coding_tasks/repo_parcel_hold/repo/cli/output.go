package cli

import (
    "encoding/json"
    "io"
    "example.com/parcel/model"
    "example.com/parcel/view"
)
func output(out io.Writer, parcel model.Parcel) error {
    return json.NewEncoder(out).Encode(view.FromModel(parcel))
}
