package service

import "example.com/batchdesk/model"

func (s *Lookup) Run(ids []string) ([]model.Result,error) {
    results := make([]model.Result,0,len(ids))
    for _,id := range ids {
        result := model.Result{ID:id}
        order,found,err := s.orders.Find(id)
        if err != nil { return nil,err }
        if !found { results=append(results,result); continue }
        customer,_,err := s.customers.Find(order.CustomerID)
        if err != nil { return nil,err }
        summary := &model.Summary{ID:order.ID,CustomerName:customer.Name,Lines:make([]model.LineView,0,len(order.Lines))}
        for _,line := range order.Lines {
            product,available,err := s.products.Find(line.SKU)
            if err != nil { return nil,err }
            summary.Lines=append(summary.Lines,lineView(line,product,available))
            summary.TotalCents += line.Quantity*product.UnitCents
        }
        result.Found=true
        result.Summary=summary
        results=append(results,result)
    }
    return results,nil
}
