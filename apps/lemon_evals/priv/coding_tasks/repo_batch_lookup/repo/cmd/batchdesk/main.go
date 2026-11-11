package main

import (
    "log"
    "net/http"
    "example.com/batchdesk/api"
    "example.com/batchdesk/app"
    "example.com/batchdesk/config"
    "example.com/batchdesk/seed"
    "example.com/batchdesk/telemetry"
)
func main() {
    lookup := app.New(seed.Demo(),&telemetry.Counters{})
    log.Fatal(http.ListenAndServe(config.Address(),api.Router(lookup)))
}
