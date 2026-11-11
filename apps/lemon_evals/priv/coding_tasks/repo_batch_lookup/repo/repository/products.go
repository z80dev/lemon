package repository

import "example.com/batchdesk/model"

type Products interface {
    Find(sku string) (model.Product,bool,error)
    FindMany(skus []string) (map[string]model.Product,error)
}
