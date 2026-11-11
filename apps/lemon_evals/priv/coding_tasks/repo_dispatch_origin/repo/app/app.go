package app

import (
    "net/http"
    "example.com/dispatch/api"
    "example.com/dispatch/repository"
    "example.com/dispatch/service"
    "example.com/dispatch/storage"
)
func Tracker(source storage.Source) *service.Tracker { return service.New(repository.New(storage.New(source))) }
func Handler(source storage.Source) http.Handler { return api.Router(Tracker(source)) }
