package integration_test

import (
    "bytes"
    "encoding/json"
    "errors"
    "fmt"
    "net/http/httptest"
    "reflect"
    "strings"
    "testing"
    "example.com/batchdesk/api"
    "example.com/batchdesk/app"
    "example.com/batchdesk/cli"
    "example.com/batchdesk/model"
    "example.com/batchdesk/seed"
    "example.com/batchdesk/service"
    "example.com/batchdesk/telemetry"
)
type orderSpy struct { rows map[string]model.Order; calls *[]telemetry.Call; err error }
func (s *orderSpy) Find(id string) (model.Order,bool,error) { *s.calls=append(*s.calls,telemetry.Call{Operation:"orders.find",Keys:[]string{id}}); v,ok:=s.rows[id]; return v,ok,s.err }
func (s *orderSpy) FindMany(ids []string) (map[string]model.Order,error) { *s.calls=append(*s.calls,telemetry.Call{Operation:"orders.batch",Keys:append([]string(nil),ids...)}); return s.rows,s.err }
type customerSpy struct { rows map[string]model.Customer; calls *[]telemetry.Call; err error }
func (s *customerSpy) Find(id string) (model.Customer,bool,error) { *s.calls=append(*s.calls,telemetry.Call{Operation:"customers.find",Keys:[]string{id}}); v,ok:=s.rows[id]; return v,ok,s.err }
func (s *customerSpy) FindMany(ids []string) (map[string]model.Customer,error) { *s.calls=append(*s.calls,telemetry.Call{Operation:"customers.batch",Keys:append([]string(nil),ids...)}); return s.rows,s.err }
type productSpy struct { rows map[string]model.Product; calls *[]telemetry.Call; err error }
func (s *productSpy) Find(id string) (model.Product,bool,error) { *s.calls=append(*s.calls,telemetry.Call{Operation:"products.find",Keys:[]string{id}}); v,ok:=s.rows[id]; return v,ok,s.err }
func (s *productSpy) FindMany(ids []string) (map[string]model.Product,error) { *s.calls=append(*s.calls,telemetry.Call{Operation:"products.batch",Keys:append([]string(nil),ids...)}); return s.rows,s.err }
func spied(orders map[string]model.Order, customers map[string]model.Customer, products map[string]model.Product, calls *[]telemetry.Call) (*service.Lookup,*orderSpy,*customerSpy,*productSpy) {
    o:=&orderSpy{rows:orders,calls:calls}; c:=&customerSpy{rows:customers,calls:calls}; p:=&productSpy{rows:products,calls:calls}
    return service.New(o,c,p),o,c,p
}
func TestFullShapeAndBoundedPlan(t *testing.T) {
    calls:=[]telemetry.Call{}
    orders:=map[string]model.Order{
        "B":{ID:"B",CustomerID:"C2",Lines:[]model.Line{{SKU:"X",Quantity:2},{SKU:"MISSING",Quantity:4},{SKU:"X",Quantity:3}}},
        "A":{ID:"A",CustomerID:"C1",Lines:[]model.Line{{SKU:"Y",Quantity:1},{SKU:"X",Quantity:1}}},
        "E":{ID:"E",CustomerID:"C2"},
        "EXTRA":{ID:"EXTRA",CustomerID:"UNREQUESTED",Lines:[]model.Line{{SKU:"NO",Quantity:1}}},
    }
    customers:=map[string]model.Customer{"C2":{ID:"C2",Name:"Second"}}
    products:=map[string]model.Product{"X":{SKU:"X",Title:"Widget",UnitCents:125},"Y":{SKU:"Y",Title:"Cable",UnitCents:200}}
    lookup,_,_,_:=spied(orders,customers,products,&calls)
    ids:=[]string{"B","absent","A","B","E","absent"}
    beforeIDs:=append([]string(nil),ids...)
    beforeRows,_:=json.Marshal(orders)
    results,err:=lookup.Run(ids)
    if err!=nil || len(results)!=len(ids) { t.Fatalf("%+v %v",results,err) }
    wantCalls:=[]telemetry.Call{
        {Operation:"orders.batch",Keys:[]string{"B","absent","A","E"}},
        {Operation:"customers.batch",Keys:[]string{"C2","C1"}},
        {Operation:"products.batch",Keys:[]string{"X","MISSING","Y"}},
    }
    if !reflect.DeepEqual(calls,wantCalls) { t.Fatalf("calls %+v want %+v",calls,wantCalls) }
    lineX:=model.LineView{SKU:"X",Title:"Widget",Quantity:2,UnitCents:125,Available:true}
    wantB:=model.Result{ID:"B",Found:true,Summary:&model.Summary{ID:"B",CustomerName:"Second",Lines:[]model.LineView{lineX,{SKU:"MISSING",Quantity:4},{SKU:"X",Title:"Widget",Quantity:3,UnitCents:125,Available:true}},TotalCents:625}}
    wantA:=model.Result{ID:"A",Found:true,Summary:&model.Summary{ID:"A",Lines:[]model.LineView{{SKU:"Y",Title:"Cable",Quantity:1,UnitCents:200,Available:true},{SKU:"X",Title:"Widget",Quantity:1,UnitCents:125,Available:true}},TotalCents:325}}
    want:=[]model.Result{wantB,{ID:"absent"},wantA,wantB,{ID:"E",Found:true,Summary:&model.Summary{ID:"E",CustomerName:"Second",Lines:[]model.LineView{}}},{ID:"absent"}}
    if !reflect.DeepEqual(results,want) { t.Fatalf("results %#v want %#v",results,want) }
    afterRows,_:=json.Marshal(orders)
    if !bytes.Equal(beforeRows,afterRows) || !reflect.DeepEqual(ids,beforeIDs) { t.Fatal("mutated repository/input") }
    calls=nil
    if _,err:=lookup.Run(ids); err!=nil || !reflect.DeepEqual(calls,wantCalls) { t.Fatalf("cross-request call plan %+v %v",calls,err) }
}
func TestEmptyMissingAndZeroLines(t *testing.T) {
    for _,tc:=range []struct{ name string; ids []string; rows map[string]model.Order; want []telemetry.Call }{
        {"nil",nil,nil,nil},
        {"empty",[]string{},nil,nil},
        {"missing",[]string{"x","x","y"},nil,[]telemetry.Call{{Operation:"orders.batch",Keys:[]string{"x","y"}}}},
        {"zero lines",[]string{"x","x"},map[string]model.Order{"x":{ID:"x",CustomerID:""}},[]telemetry.Call{{Operation:"orders.batch",Keys:[]string{"x"}},{Operation:"customers.batch",Keys:[]string{""}}}},
        {"opaque empty",[]string{""," ",""},map[string]model.Order{"":{ID:"",CustomerID:"",Lines:[]model.Line{{SKU:"",Quantity:1}}}},[]telemetry.Call{{Operation:"orders.batch",Keys:[]string{""," "}},{Operation:"customers.batch",Keys:[]string{""}},{Operation:"products.batch",Keys:[]string{""}}}},
    } { t.Run(tc.name,func(t *testing.T){
        var calls []telemetry.Call
        lookup,_,_,_:=spied(tc.rows,nil,nil,&calls)
        got,err:=lookup.Run(tc.ids)
        if err!=nil || got==nil || len(got)!=len(tc.ids) || !reflect.DeepEqual(calls,tc.want) { t.Fatalf("results=%+v calls=%+v err=%v",got,calls,err) }
        for _,result:=range got {
            if result.Found && result.Summary.Lines==nil { t.Fatal("nil lines") }
            if !result.Found && result.Summary!=nil { t.Fatal("missing summary not nil") }
        }
    }) }
}
func TestBatchFailureIdentityAndShortCircuit(t *testing.T) {
    for stage:=0;stage<3;stage++ {
        var calls []telemetry.Call
        lookup,o,c,p:=spied(map[string]model.Order{"O":{ID:"O",CustomerID:"C",Lines:[]model.Line{{SKU:"P",Quantity:1}}}},nil,nil,&calls)
        sentinel:=fmt.Errorf("failure %d",stage)
        switch stage { case 0:o.err=sentinel; case 1:c.err=sentinel; case 2:p.err=sentinel }
        got,err:=lookup.Run([]string{"O","O"})
        if err!=sentinel || got!=nil || len(calls)!=stage+1 { t.Fatalf("stage %d got=%+v err=%v calls=%+v",stage,got,err,calls) }
        operations:=[]string{"orders.batch","customers.batch","products.batch"}
        for i,call:=range calls { if call.Operation!=operations[i] { t.Fatalf("call=%+v",call) } }
        var out bytes.Buffer
        if err:=cli.Run([]string{"O"},lookup,&out); err!=sentinel || out.Len()!=0 { t.Fatalf("CLI err=%v output=%q",err,out.String()) }
        w:=httptest.NewRecorder(); api.Router(lookup).ServeHTTP(w,httptest.NewRequest("POST","/v1/orders/lookup",strings.NewReader(`{"ids":["O"]}`)))
        var body map[string]string; _=json.Unmarshal(w.Body.Bytes(),&body)
        if w.Code!=500 || body["error"]!="lookup failed" { t.Fatalf("%d %s",w.Code,w.Body.String()) }
    }
}
func TestLargeSharedGraphCallCount(t *testing.T) {
    data:=seed.Data{Customers:[]model.Customer{{ID:"C",Name:"Shared"}},Products:[]model.Product{{SKU:"P",Title:"Shared",UnitCents:17}}}
    ids:=make([]string,0,240)
    for i:=0;i<120;i++ { id:=fmt.Sprintf("O%03d",i); data.Orders=append(data.Orders,model.Order{ID:id,CustomerID:"C",Lines:[]model.Line{{SKU:"P",Quantity:2},{SKU:"P",Quantity:3}}}); ids=append(ids,id,id) }
    counts:=&telemetry.Counters{}
    result,err:=app.New(data,counts).Run(ids)
    calls:=counts.Calls()
    if err!=nil || len(result)!=240 || len(calls)!=3 || len(calls[0].Keys)!=120 || !reflect.DeepEqual(calls[1].Keys,[]string{"C"}) || !reflect.DeepEqual(calls[2].Keys,[]string{"P"}) { t.Fatalf("calls=%+v len=%d err=%v",calls,len(result),err) }
    for _,row:=range result { if row.Summary.TotalCents!=85 { t.Fatalf("%+v",row) } }
}
func TestHTTPCLIAndInspector(t *testing.T) {
    counts:=&telemetry.Counters{}
    lookup:=app.New(seed.Demo(),counts)
    w:=httptest.NewRecorder()
    api.Router(lookup).ServeHTTP(w,httptest.NewRequest("POST","/v1/orders/lookup",strings.NewReader(`{"ids":["O2","missing","O1","O2"]}`)))
    var httpBody any
    if err:=json.Unmarshal(w.Body.Bytes(),&httpBody); err!=nil || w.Code!=200 { t.Fatalf("%d %s %v",w.Code,w.Body.String(),err) }
    if got:=counts.Calls(); len(got)!=3 || got[0].Operation!="orders.batch" || got[1].Operation!="customers.batch" || got[2].Operation!="products.batch" { t.Fatalf("%+v",got) }
    var out bytes.Buffer
    if err:=cli.Run([]string{"O2","missing","O1","O2"},lookup,&out); err!=nil { t.Fatal(err) }
    var cliBody any; _=json.Unmarshal(out.Bytes(),&cliBody)
    if !reflect.DeepEqual(cliBody,httpBody) { t.Fatalf("CLI %s HTTP %s",out.String(),w.Body.String()) }
    var calls []telemetry.Call
    _,orders,_,_:=spied(map[string]model.Order{"x":{ID:"x"}},nil,nil,&calls)
    order,found,err:=service.NewInspector(orders).Order("x")
    if err!=nil || !found || order.ID!="x" || len(calls)!=1 || calls[0].Operation!="orders.find" { t.Fatalf("inspector %+v %v %+v",order,err,calls) }
    bad:=httptest.NewRecorder()
    api.Router(lookup).ServeHTTP(bad,httptest.NewRequest("POST","/v1/orders/lookup",strings.NewReader(`{"ids":[3]}`)))
    if bad.Code!=400 { t.Fatal(bad.Code) }
}
func TestErrorsRemainDistinct(t *testing.T) {
    sentinel:=errors.New("offline")
    var calls []telemetry.Call
    lookup,o,_,_:=spied(nil,nil,nil,&calls); o.err=sentinel
    result,err:=lookup.Run([]string{"missing"})
    if result!=nil || !errors.Is(err,sentinel) { t.Fatalf("%+v %v",result,err) }
}
