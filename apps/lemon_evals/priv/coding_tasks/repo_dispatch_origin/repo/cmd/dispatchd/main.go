package main

import (
    "log"
    "net/http"
    "example.com/dispatch/app"
    "example.com/dispatch/config"
    "example.com/dispatch/seed"
)
func main() { log.Fatal(http.ListenAndServe(config.Address(),app.Handler(seed.Demo()))) }
