package integration_test

import (
    "bytes"
    "encoding/json"
    "errors"
    "net/http"
    "net/http/httptest"
    "os"
    "path/filepath"
    "reflect"
    "strings"
    "sync"
    "testing"
    "example.com/parcel/api"
    "example.com/parcel/app"
    "example.com/parcel/cli"
    "example.com/parcel/model"
    "example.com/parcel/service"
    "example.com/parcel/storage"
)
func fixture(t *testing.T) (*storage.Store,*service.Desk,string) {
    t.Helper()
    path := filepath.Join(t.TempDir(),"parcels.json")
    db,err := storage.Open(path); if err != nil { t.Fatal(err) }
    for _, p := range []model.Parcel{
        {ID:"P1",Destination:"Oslo",State:model.Ready,Revision:7},
        {ID:"D1",Destination:"Paris",State:model.Delivered,Revision:11},
    } { if _,err := db.Create(p); err != nil { t.Fatal(err) } }
    return db,service.New(db),path
}
func request(t *testing.T, handler http.Handler, method,path,body string) (int,map[string]any) {
    t.Helper()
    w := httptest.NewRecorder()
    handler.ServeHTTP(w,httptest.NewRequest(method,path,strings.NewReader(body)))
    var result map[string]any
    if err := json.Unmarshal(w.Body.Bytes(),&result); err != nil { t.Fatalf("JSON %q: %v",w.Body.String(),err) }
    if w.Header().Get("Content-Type") != "application/json" { t.Fatal("missing JSON content type") }
    return w.Code,result
}
func expected(reason any, revision float64) map[string]any {
    return map[string]any{"id":"P1","destination":"Oslo","state":"ready","revision":revision,"hold":reason}
}
func TestHTTPCLIAndRestart(t *testing.T) {
    _,desk,path := fixture(t)
    handler := api.Router(desk)
    status,body := request(t,handler,"GET","/v1/parcels/P1","")
    if status != 200 || !reflect.DeepEqual(body,expected(nil,7)) { t.Fatalf("%d %#v",status,body) }
    status,body = request(t,handler,"POST","/v1/parcels/P1/hold",`{"reason":"  customs review  "}`)
    want := expected(map[string]any{"reason":"customs review"},8)
    if status != 200 || !reflect.DeepEqual(body,want) { t.Fatalf("%d %#v",status,body) }
    reopened,err := app.Open(path); if err != nil { t.Fatal(err) }
    var out bytes.Buffer
    if err := cli.Run([]string{"show","P1"},reopened,&out); err != nil { t.Fatal(err) }
    var got map[string]any; _ = json.Unmarshal(out.Bytes(),&got)
    if !reflect.DeepEqual(got,want) || !strings.HasSuffix(out.String(),"\n") { t.Fatalf("CLI show %s",out.String()) }
    out.Reset()
    if err := cli.Run([]string{"release","P1"},reopened,&out); err != nil { t.Fatal(err) }
    _ = json.Unmarshal(out.Bytes(),&got)
    if !reflect.DeepEqual(got,expected(nil,9)) { t.Fatalf("CLI release %s",out.String()) }
    latest,err := app.Open(path); if err != nil { t.Fatal(err) }
    status,body = request(t,api.Router(latest),"GET","/v1/parcels/P1","")
    if status != 200 || !reflect.DeepEqual(body,expected(nil,9)) { t.Fatalf("restart %d %#v",status,body) }
    out.Reset()
    if err := cli.Run([]string{"hold","P1","待機"},latest,&out); err != nil { t.Fatal(err) }
    _ = json.Unmarshal(out.Bytes(),&got)
    if !reflect.DeepEqual(got,expected(map[string]any{"reason":"待機"},10)) { t.Fatal(out.String()) }
    latest,_ = app.Open(path)
    status,body = request(t,api.Router(latest),"DELETE","/v1/parcels/P1/hold","")
    if status != 200 || !reflect.DeepEqual(body,expected(nil,11)) { t.Fatalf("release %d %#v",status,body) }
}
func TestValidationConflictAndIdempotency(t *testing.T) {
    db,desk,path := fixture(t)
    for _, reason := range []string{""," \t\n",strings.Repeat("界",121)} {
        if _,err := desk.PlaceHold("missing",reason); !errors.Is(err,model.ErrInvalidReason) { t.Fatalf("reason %q: %v",reason,err) }
    }
    if _,err := desk.PlaceHold("missing","valid"); !errors.Is(err,model.ErrNotFound) { t.Fatal(err) }
    if _,err := desk.ReleaseHold("missing"); !errors.Is(err,model.ErrNotFound) { t.Fatal(err) }
    reason := strings.Repeat("界",120)
    p,err := desk.PlaceHold("P1","\u2003"+reason+"\u2003")
    if err != nil || p.Revision != 8 || p.Hold == nil || p.Hold.Reason != reason { t.Fatalf("%+v %v",p,err) }
    original,_ := os.ReadFile(path)
    info,_ := os.Stat(path)
    p,err = desk.PlaceHold("P1",reason)
    afterInfo,_ := os.Stat(path)
    if err != nil || p.Revision != 8 || !os.SameFile(info,afterInfo) { t.Fatalf("identical hold rewrote snapshot: %+v %v",p,err) }
    if _,err := desk.PlaceHold("P1","different"); !errors.Is(err,model.ErrAlreadyHeld) { t.Fatal(err) }
    if _,err := desk.PlaceHold("D1","valid"); !errors.Is(err,model.ErrDelivered) { t.Fatal(err) }
    after,_ := os.ReadFile(path)
    if !bytes.Equal(original,after) { t.Fatal("rejected request changed snapshot") }
    p,err = desk.ReleaseHold("D1")
    if err != nil || p.Revision != 11 || p.Hold != nil { t.Fatalf("%+v %v",p,err) }
    if newInfo,_ := os.Stat(path); !os.SameFile(info,newInfo) { t.Fatal("no-op release wrote to disk") }
    p,err = desk.ReleaseHold("P1")
    if err != nil || p.Hold != nil || p.Revision != 9 { t.Fatalf("%+v %v",p,err) }
    info,_ = os.Stat(path)
    p,err = desk.ReleaseHold("P1")
    if err != nil || p.Revision != 9 { t.Fatalf("%+v %v",p,err) }
    if newInfo,_ := os.Stat(path); !os.SameFile(info,newInfo) { t.Fatal("repeat release wrote to disk") }
    _,_ = db.Update("D1",func(p *model.Parcel) (bool,error) { p.Hold=&model.Hold{Reason:"legacy"}; return true,nil })
    if _,err := desk.PlaceHold("D1","legacy"); !errors.Is(err,model.ErrDelivered) { t.Fatalf("delivered precedence: %v",err) }
    p,err = desk.ReleaseHold("D1")
    if err != nil || p.Hold != nil || p.Revision != 12 { t.Fatalf("delivered release: %+v %v",p,err) }
}
func TestHTTPInputAndErrors(t *testing.T) {
    _,desk,_ := fixture(t); h := api.Router(desk)
    for _, body := range []string{`null`,`[]`,`"x"`,`1`,`{`,`{"reason":null}`,`{"reason":4}`,`{"reason":true}`,`{"reason":"x","extra":1}`,`{"reason":"x"} {}`,`{"reason":"x"} junk`} {
        status,value := request(t,h,"POST","/v1/parcels/P1/hold",body)
        if status != 400 || !reflect.DeepEqual(value,map[string]any{"error":"invalid request"}) { t.Fatalf("body %s: %d %#v",body,status,value) }
    }
    for _, body := range []string{`{}`,`{"reason":""}`,`{"reason":"   "}`} {
        status,value := request(t,h,"POST","/v1/parcels/P1/hold",body)
        if status != 400 || value["error"] != model.ErrInvalidReason.Error() { t.Fatalf("%d %#v",status,value) }
    }
    for _, tc := range []struct{ method,id,body,message string; status int }{
        {"POST","none",`{"reason":"x"}`,"parcel not found",404},
        {"DELETE","none","","parcel not found",404},
        {"POST","D1",`{"reason":"x"}`,"delivered parcel cannot be held",409},
    } {
        status,value := request(t,h,tc.method,"/v1/parcels/"+tc.id+"/hold",tc.body)
        if status != tc.status || !reflect.DeepEqual(value,map[string]any{"error":tc.message}) { t.Fatalf("%d %#v",status,value) }
    }
    _,_ = desk.PlaceHold("P1","first")
    status,value := request(t,h,"POST","/v1/parcels/P1/hold",`{"reason":"second"}`)
    if status != 409 || value["error"] != "parcel already held" { t.Fatalf("%d %#v",status,value) }
}
func TestCopyAndOldSnapshot(t *testing.T) {
    db,desk,path := fixture(t)
    p,err := desk.PlaceHold("P1","original"); if err != nil { t.Fatal(err) }
    p.Hold.Reason="corrupt"
    p,_ = desk.Show("P1")
    if p.Hold == nil || p.Hold.Reason != "original" { t.Fatal("returned hold aliases storage") }
    p.Hold.Reason="another corrupt"
    p,_ = db.Get("P1")
    if p.Hold.Reason != "original" { t.Fatal("Get aliases storage") }
    incoming := model.Parcel{ID:"P2",State:model.Ready,Hold:&model.Hold{Reason:"incoming"}}
    created,err := db.Create(incoming); if err != nil { t.Fatal(err) }
    incoming.Hold.Reason="input mutation"; created.Hold.Reason="result mutation"
    got,_ := db.Get("P2")
    if got.Hold == nil || got.Hold.Reason != "incoming" { t.Fatal("Create aliases hold") }
    _,err = db.Update("P1",func(p *model.Parcel) (bool,error) { p.Hold.Reason="rejected"; return false,errors.New("reject") })
    got,_ = db.Get("P1")
    if err == nil || got.Hold.Reason != "original" { t.Fatal("failed callback changed hold") }
    oldPath := filepath.Join(filepath.Dir(path),"old.json")
    if err := os.WriteFile(oldPath,[]byte(`{"records":{"OLD":{"id":"OLD","destination":"Riga","state":"ready","revision":3}}}`),0600); err != nil { t.Fatal(err) }
    old,err := storage.Open(oldPath); if err != nil { t.Fatal(err) }
    oldP,err := old.Get("OLD")
    if err != nil || oldP.Hold != nil || oldP.Revision != 3 { t.Fatalf("%+v %v",oldP,err) }
}
func TestPersistenceFailureDoesNotPublish(t *testing.T) {
    db,desk,path := fixture(t)
    before,_ := os.ReadFile(path)
    if err := os.Remove(path); err != nil { t.Fatal(err) }
    if err := os.Mkdir(path,0700); err != nil { t.Fatal(err) }
    if _,err := desk.PlaceHold("P1","will fail"); err == nil { t.Fatal("expected persistence failure") }
    got,_ := db.Get("P1")
    if got.Hold != nil || got.Revision != 7 { t.Fatalf("failed save published %+v",got) }
    status,value := request(t,api.Router(desk),"POST","/v1/parcels/P1/hold",`{"reason":"fail"}`)
    if status != 500 || !reflect.DeepEqual(value,map[string]any{"error":"internal error"}) { t.Fatalf("%d %#v",status,value) }
    if err := os.Remove(path); err != nil { t.Fatal(err) }
    if err := os.WriteFile(path,before,0600); err != nil { t.Fatal(err) }
    if _,err := desk.PlaceHold("P1","saved"); err != nil { t.Fatal(err) }
    held,_ := os.ReadFile(path)
    if err := os.Remove(path); err != nil { t.Fatal(err) }
    if err := os.Mkdir(path,0700); err != nil { t.Fatal(err) }
    if _,err := desk.ReleaseHold("P1"); err == nil { t.Fatal("expected release save failure") }
    got,_ = db.Get("P1")
    if got.Hold == nil || got.Hold.Reason != "saved" || got.Revision != 8 { t.Fatalf("failed release published %+v",got) }
    if err := os.Remove(path); err != nil { t.Fatal(err) }
    if err := os.WriteFile(path,held,0600); err != nil { t.Fatal(err) }
}
func TestCLIUsageAndErrors(t *testing.T) {
    _,desk,_ := fixture(t)
    for _, args := range [][]string{nil,{"bad"},{"show"},{"show","P1","extra"},{"hold","P1"},{"hold","P1","x","extra"},{"release"},{"release","P1","x"}} {
        var out bytes.Buffer
        err := cli.Run(args,desk,&out)
        if err == nil || err.Error() != "usage: parcel show ID | hold ID REASON | release ID" || out.Len() != 0 { t.Fatalf("%v %v %s",args,err,out.String()) }
    }
    for _, tc := range []struct{ args []string; want error }{
        {[]string{"hold","P1"," "},model.ErrInvalidReason},
        {[]string{"hold","D1","x"},model.ErrDelivered},
        {[]string{"release","missing"},model.ErrNotFound},
    } {
        var out bytes.Buffer
        if err := cli.Run(tc.args,desk,&out); !errors.Is(err,tc.want) || out.Len() != 0 { t.Fatalf("%v %v %s",tc.args,err,out.String()) }
    }
}
func TestConcurrentSameReasonIsOneMutation(t *testing.T) {
    _,desk,_ := fixture(t)
    var wg sync.WaitGroup
    errs := make(chan error,16)
    for i:=0;i<16;i++ { wg.Add(1); go func(){ defer wg.Done(); _,err:=desk.PlaceHold("P1","same"); errs<-err }() }
    wg.Wait(); close(errs)
    for err := range errs { if err != nil { t.Fatal(err) } }
    p,_ := desk.Show("P1")
    if p.Revision != 8 || p.Hold == nil || p.Hold.Reason != "same" { t.Fatalf("%+v",p) }
}
