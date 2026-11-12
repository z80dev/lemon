package memory

import "example.com/batchdesk/model"

func (r *Products) FindMany(skus []string) (map[string]model.Product,error) {
    r.counters.Record("products.batch",skus)
    result := make(map[string]model.Product,len(skus))
    for _,sku := range skus { if row,ok := r.rows[sku]; ok { result[sku]=row } }
    return result,nil
}
