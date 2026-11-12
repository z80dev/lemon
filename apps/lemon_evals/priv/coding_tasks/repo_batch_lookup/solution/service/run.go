package service

import "example.com/batchdesk/model"

func (s *Lookup) Run(ids []string) ([]model.Result,error) {
    results := make([]model.Result,0,len(ids))
    if len(ids) == 0 { return results,nil }
    requested := make([]string,0,len(ids))
    seenOrders := make(map[string]struct{},len(ids))
    for _,id := range ids {
        if _,exists := seenOrders[id]; !exists { seenOrders[id]=struct{}{}; requested=append(requested,id) }
    }
    orders,err := s.orders.FindMany(requested)
    if err != nil { return nil,err }
    customerIDs := make([]string,0)
    skus := make([]string,0)
    seenCustomers := make(map[string]struct{})
    seenProducts := make(map[string]struct{})
    for _,id := range requested {
        order,found := orders[id]
        if !found { continue }
        if _,exists := seenCustomers[order.CustomerID]; !exists {
            seenCustomers[order.CustomerID]=struct{}{}
            customerIDs=append(customerIDs,order.CustomerID)
        }
        for _,line := range order.Lines {
            if _,exists := seenProducts[line.SKU]; !exists {
                seenProducts[line.SKU]=struct{}{}
                skus=append(skus,line.SKU)
            }
        }
    }
    var customers map[string]model.Customer
    if len(customerIDs) > 0 {
        customers,err=s.customers.FindMany(customerIDs)
        if err != nil { return nil,err }
    }
    var products map[string]model.Product
    if len(skus) > 0 {
        products,err=s.products.FindMany(skus)
        if err != nil { return nil,err }
    }
    for _,id := range ids {
        result := model.Result{ID:id}
        order,found := orders[id]
        if found {
            summary := &model.Summary{ID:order.ID,CustomerName:customers[order.CustomerID].Name,Lines:make([]model.LineView,0,len(order.Lines))}
            for _,line := range order.Lines {
                product,available := products[line.SKU]
                summary.Lines=append(summary.Lines,lineView(line,product,available))
                summary.TotalCents += line.Quantity*product.UnitCents
            }
            result.Found=true
            result.Summary=summary
        }
        results=append(results,result)
    }
    return results,nil
}
