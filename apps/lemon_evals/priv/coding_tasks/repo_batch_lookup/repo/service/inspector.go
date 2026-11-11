package service

import (
    "example.com/batchdesk/model"
    "example.com/batchdesk/repository"
)
type Inspector struct { orders repository.Orders }
func NewInspector(orders repository.Orders) *Inspector { return &Inspector{orders:orders} }
func (i *Inspector) Order(id string) (model.Order,bool,error) { return i.orders.Find(id) }
