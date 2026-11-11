package main

import (
    "log"
    "net/http"
    "example.com/parcel/api"
    "example.com/parcel/app"
    "example.com/parcel/config"
)
func main() {
    desk,err := app.Open(config.StorePath())
    if err != nil { log.Fatal(err) }
    log.Fatal(http.ListenAndServe(config.Address(),api.Router(desk)))
}
