package memory

import "example.com/batchdesk/model"

func (r *Orders) FindMany(ids []string) (map[string]model.Order,error) {
    r.counters.Record("orders.batch",ids)
    result := make(map[string]model.Order,len(ids))
    for _,id := range ids { if row,ok := r.rows[id]; ok { result[id]=cloneOrder(row) } }
    return result,nil
}
