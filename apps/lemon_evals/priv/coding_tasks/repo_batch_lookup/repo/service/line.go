package service

import "example.com/batchdesk/model"

func lineView(line model.Line, product model.Product, available bool) model.LineView {
    return model.LineView{SKU:line.SKU,Title:product.Title,Quantity:line.Quantity,UnitCents:product.UnitCents,Available:available}
}
