package app

import (
    "example.com/parcel/service"
    "example.com/parcel/storage"
)
func Open(path string) (*service.Desk,error) {
    store,err := storage.Open(path)
    if err != nil { return nil,err }
    return service.New(store),nil
}
