package storage_test

import (
    "errors"
    "path/filepath"
    "testing"
    "example.com/parcel/model"
    "example.com/parcel/storage"
)
func TestRoundTrip(t *testing.T) {
    path := filepath.Join(t.TempDir(),"parcels.json")
    store,err := storage.Open(path); if err != nil { t.Fatal(err) }
    _,err = store.Create(model.Parcel{ID:"P1",Destination:"Oslo",State:model.Ready,Revision:7})
    if err != nil { t.Fatal(err) }
    again,err := storage.Open(path); if err != nil { t.Fatal(err) }
    p,err := again.Get("P1")
    if err != nil || p.Destination != "Oslo" || p.Revision != 7 { t.Fatalf("%+v %v",p,err) }
    if _,err := again.Get("absent"); !errors.Is(err,model.ErrNotFound) { t.Fatal(err) }
}
func TestFailedCallbackDoesNotPublish(t *testing.T) {
    store,_ := storage.Open(filepath.Join(t.TempDir(),"parcels.json"))
    _,_ = store.Create(model.Parcel{ID:"P1",Destination:"Oslo",State:model.Ready})
    sentinel := errors.New("reject")
    _,err := store.Update("P1",func(p *model.Parcel) (bool,error) { p.Destination="wrong"; return true,sentinel })
    if !errors.Is(err,sentinel) { t.Fatal(err) }
    p,_ := store.Get("P1")
    if p.Destination != "Oslo" { t.Fatal("failed transaction was published") }
}
