package model

type Order struct {
    ID string
    CustomerID string
    Lines []Line
}
type Line struct {
    SKU string
    Quantity int64
}
