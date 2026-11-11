package memory_test

import (
    "testing"
    "example.com/batchdesk/memory"
    "example.com/batchdesk/model"
)
func TestBatchDoesNotExposeStoredLines(t *testing.T) {
    orders := memory.NewOrders([]model.Order{{ID:"O",Lines:[]model.Line{{SKU:"A",Quantity:1}}}},nil)
    rows,_ := orders.FindMany([]string{"O"})
    rows["O"].Lines[0].SKU="corrupt"
    row,_,_ := orders.Find("O")
    if row.Lines[0].SKU != "A" { t.Fatal("shared lines") }
}
