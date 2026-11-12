package repository

import "example.com/batchdesk/model"

type Customers interface {
    Find(id string) (model.Customer,bool,error)
    FindMany(ids []string) (map[string]model.Customer,error)
}
