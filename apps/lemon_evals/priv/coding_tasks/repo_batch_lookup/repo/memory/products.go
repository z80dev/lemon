package memory

import (
    "example.com/batchdesk/model"
    "example.com/batchdesk/telemetry"
)
type Products struct { rows map[string]model.Product; counters *telemetry.Counters }
func NewProducts(rows []model.Product,counters *telemetry.Counters) *Products {
    result := &Products{rows:make(map[string]model.Product,len(rows)),counters:counters}
    for _,row := range rows { result.rows[row.SKU]=row }
    return result
}
func (r *Products) Find(sku string) (model.Product,bool,error) {
    r.counters.Record("products.find",[]string{sku})
    row,ok := r.rows[sku]
    return row,ok,nil
}
