package memory

import (
    "example.com/batchdesk/model"
    "example.com/batchdesk/telemetry"
)
type Orders struct { rows map[string]model.Order; counters *telemetry.Counters }
func NewOrders(rows []model.Order, counters *telemetry.Counters) *Orders {
    result := &Orders{rows:make(map[string]model.Order,len(rows)),counters:counters}
    for _,row := range rows { result.rows[row.ID] = cloneOrder(row) }
    return result
}
func cloneOrder(order model.Order) model.Order {
    order.Lines=append([]model.Line(nil),order.Lines...)
    return order
}
func (r *Orders) Find(id string) (model.Order,bool,error) {
    r.counters.Record("orders.find",[]string{id})
    row,ok := r.rows[id]
    return cloneOrder(row),ok,nil
}
