package service_test

import (
    "reflect"
    "testing"
    "example.com/batchdesk/app"
    "example.com/batchdesk/seed"
    "example.com/batchdesk/telemetry"
)
func TestOutputOrdering(t *testing.T) {
    lookup := app.New(seed.Demo(),&telemetry.Counters{})
    results,err := lookup.Run([]string{"O2","missing","O1","O2"})
    if err != nil || len(results) != 4 { t.Fatalf("%+v %v",results,err) }
    if results[0].Summary.TotalCents != 450 || results[1].Found || results[1].Summary != nil || results[2].Summary.TotalCents != 2100 || !reflect.DeepEqual(results[0],results[3]) { t.Fatalf("%+v",results) }
}
func TestOneBatchPerRepository(t *testing.T) {
    counters := &telemetry.Counters{}
    _,err := app.New(seed.Demo(),counters).Run([]string{"O1","O2","O1"})
    if err != nil { t.Fatal(err) }
    want := []telemetry.Call{
        {Operation:"orders.batch",Keys:[]string{"O1","O2"}},
        {Operation:"customers.batch",Keys:[]string{"C1"}},
        {Operation:"products.batch",Keys:[]string{"TEA","MUG"}},
    }
    if got := counters.Calls(); !reflect.DeepEqual(got,want) { t.Fatalf("calls=%+v want=%+v",got,want) }
}
