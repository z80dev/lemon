package seed

import "example.com/batchdesk/model"

type Data struct {
    Orders []model.Order
    Customers []model.Customer
    Products []model.Product
}
func Demo() Data {
    return Data{
        Orders:[]model.Order{
            {ID:"O1",CustomerID:"C1",Lines:[]model.Line{{SKU:"TEA",Quantity:2},{SKU:"MUG",Quantity:1}}},
            {ID:"O2",CustomerID:"C1",Lines:[]model.Line{{SKU:"TEA",Quantity:1}}},
        },
        Customers:[]model.Customer{{ID:"C1",Name:"Aster Shop"}},
        Products:[]model.Product{{SKU:"TEA",Title:"Black tea",UnitCents:450},{SKU:"MUG",Title:"Stone mug",UnitCents:1200}},
    }
}
