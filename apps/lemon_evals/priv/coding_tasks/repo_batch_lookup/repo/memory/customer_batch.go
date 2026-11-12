package memory

import "example.com/batchdesk/model"

func (r *Customers) FindMany(ids []string) (map[string]model.Customer,error) {
    r.counters.Record("customers.batch",ids)
    result := make(map[string]model.Customer,len(ids))
    for _,id := range ids { if row,ok := r.rows[id]; ok { result[id]=row } }
    return result,nil
}
