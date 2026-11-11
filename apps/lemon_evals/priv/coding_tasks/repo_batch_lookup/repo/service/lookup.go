package service

import "example.com/batchdesk/repository"

type Lookup struct {
    orders repository.Orders
    customers repository.Customers
    products repository.Products
}
func New(orders repository.Orders,customers repository.Customers,products repository.Products) *Lookup {
    return &Lookup{orders:orders,customers:customers,products:products}
}
