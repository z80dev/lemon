package memory

import (
    "example.com/batchdesk/model"
    "example.com/batchdesk/telemetry"
)
type Customers struct { rows map[string]model.Customer; counters *telemetry.Counters }
func NewCustomers(rows []model.Customer,counters *telemetry.Counters) *Customers {
    result := &Customers{rows:make(map[string]model.Customer,len(rows)),counters:counters}
    for _,row := range rows { result.rows[row.ID]=row }
    return result
}
func (r *Customers) Find(id string) (model.Customer,bool,error) {
    r.counters.Record("customers.find",[]string{id})
    row,ok := r.rows[id]
    return row,ok,nil
}
