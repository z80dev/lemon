package repository

import "example.com/batchdesk/model"

type Orders interface {
    Find(id string) (model.Order,bool,error)
    FindMany(ids []string) (map[string]model.Order,error)
}
