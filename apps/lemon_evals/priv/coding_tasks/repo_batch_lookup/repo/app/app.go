package app

import (
    "example.com/batchdesk/memory"
    "example.com/batchdesk/seed"
    "example.com/batchdesk/service"
    "example.com/batchdesk/telemetry"
)
func New(data seed.Data,counters *telemetry.Counters) *service.Lookup {
    return service.New(memory.NewOrders(data.Orders,counters),memory.NewCustomers(data.Customers,counters),memory.NewProducts(data.Products,counters))
}
