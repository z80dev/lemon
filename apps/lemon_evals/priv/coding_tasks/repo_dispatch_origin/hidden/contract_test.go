package integration_test

import (
    "bytes"
    "encoding/json"
    "errors"
    "net/http/httptest"
    "reflect"
    "testing"
    "time"
    "example.com/dispatch/app"
    "example.com/dispatch/cli"
    "example.com/dispatch/ledger"
    "example.com/dispatch/model"
    "example.com/dispatch/storage"
    "example.com/dispatch/view"
)
func instant(s string) time.Time { v,e := time.Parse(time.RFC3339,s); if e != nil { panic(e) }; return v }
func dispatchDB(events []ledger.EventRow) *ledger.Memory {
    db := ledger.New()
    db.Put(ledger.DispatchRow{Account:"a",ID:"d",Reference:"REF",Status:"delivered"})
    for _, row := range events { db.Append(row) }
    return db
}
func event(kind,hub,at string,seq int64) ledger.EventRow {
    return ledger.EventRow{Account:"a",DispatchID:"d",Kind:kind,Hub:hub,At:instant(at),Sequence:seq}
}
func TestOriginThroughAllLayers(t *testing.T) {
    early := event("accepted","ORIGIN","2026-04-01T08:00:00Z",1)
    later := event("accepted","TRANSFER","2026-04-01T09:00:00Z",3)
    moved := event("moved","LATEST","2026-04-01T10:00:00Z",4)
    audit := event("audit","NOT-A-HUB","2027-01-01T00:00:00Z",5)
    foreign := early; foreign.Account="b"; foreign.Hub="FOREIGN"
    foreignID := early; foreignID.DispatchID="other"; foreignID.Hub="OTHER"
    for _, rows := range [][]ledger.EventRow{
        {early,later,moved,audit,foreign,foreignID},
        {audit,moved,later,early,foreignID,foreign},
        {later,early,audit,moved,foreign,foreignID},
    } {
        db := dispatchDB(rows)
        handler := app.Handler(db)
        req := httptest.NewRequest("GET","/v1/dispatches/d",nil)
        req.Header.Set("X-Account"," a ")
        response := httptest.NewRecorder(); handler.ServeHTTP(response,req)
        var got map[string]any
        if err := json.Unmarshal(response.Body.Bytes(),&got); err != nil { t.Fatal(err) }
        want := map[string]any{"id":"d","reference":"REF","status":"delivered","origin":map[string]any{"hub":"ORIGIN","at":"2026-04-01T08:00:00Z"},"latest_hub":"LATEST"}
        if response.Code != 200 || !reflect.DeepEqual(got,want) { t.Fatalf("HTTP %d: %#v",response.Code,got) }
        var output bytes.Buffer
        if err := cli.Run([]string{"a","d"},app.Tracker(db),&output); err != nil { t.Fatal(err) }
        var fromCLI map[string]any
        if err := json.Unmarshal(output.Bytes(),&fromCLI); err != nil || !reflect.DeepEqual(fromCLI,want) { t.Fatalf("CLI: %s (%v)",output.String(),err) }
    }
}
func TestNullOriginAndLatestTie(t *testing.T) {
    cases := []struct{ name string; rows []ledger.EventRow; origin,latest string }{
        {"empty",nil,"",""},
        {"audit only",[]ledger.EventRow{event("audit","X","2026-01-01T00:00:00Z",1)},"",""},
        {"moved only",[]ledger.EventRow{event("moved","M","2026-01-01T00:00:00Z",1)},"","M"},
        {"instant and sequence",[]ledger.EventRow{
            event("accepted","LOW","2026-01-01T01:00:00+01:00",2),
            event("accepted","HIGH","2026-01-01T00:00:00Z",9),
            event("moved","LATEST","2026-01-01T00:00:00Z",10),
        },"LOW","LATEST"},
        {"time before sequence",[]ledger.EventRow{
            event("accepted","EARLY","2026-01-01T00:00:00Z",90),
            event("accepted","LATE","2026-01-01T00:00:01Z",1),
        },"EARLY","LATE"},
    }
    for _, tc := range cases { t.Run(tc.name,func(t *testing.T) {
        got,err := app.Tracker(dispatchDB(tc.rows)).Lookup("a","d")
        if err != nil { t.Fatal(err) }
        if tc.origin == "" { if got.Origin != nil { t.Fatalf("expected nil origin: %+v",got.Origin) } } else if got.Origin == nil || got.Origin.Hub != tc.origin { t.Fatalf("origin=%+v",got.Origin) }
        if got.LatestHub != tc.latest { t.Fatalf("latest=%q",got.LatestHub) }
        if tc.origin == "" { encoded,_ := json.Marshal(view.FromModel(got)); var v map[string]any; _ = json.Unmarshal(encoded,&v); if v["origin"] != nil { t.Fatal(string(encoded)) } }
    }) }
}
type noisy struct { rows []ledger.EventRow; failure error }
func (n noisy) Dispatch(account,id string) (ledger.DispatchRow,error) { return ledger.DispatchRow{Account:account,ID:id,Status:"in_transit"},nil }
func (n noisy) Events(account,id string) ([]ledger.EventRow,error) { return n.rows,n.failure }
func TestAdapterIsolationAndOwnership(t *testing.T) {
    rows := []ledger.EventRow{event("accepted","OK","2026-01-01T00:00:00Z",1)}
    foreign := event("accepted","BAD","2025-01-01T00:00:00Z",1); foreign.Account="b"
    wrong := foreign; wrong.Account="a"; wrong.DispatchID="wrong"
    rows = append(rows,foreign,wrong)
    before := append([]ledger.EventRow(nil),rows...)
    adapter := storage.New(noisy{rows:rows})
    first,err := adapter.Load("a","d"); if err != nil { t.Fatal(err) }
    if first.Origin == nil || first.Origin.Hub != "OK" { t.Fatalf("origin %+v",first.Origin) }
    first.Origin.Hub="mutated"
    second,_ := adapter.Load("a","d")
    if second.Origin == nil || second.Origin.Hub != "OK" || !reflect.DeepEqual(before,rows) { t.Fatal("read mutated shared data") }
    sentinel := errors.New("read failed")
    if _,err := storage.New(noisy{failure:sentinel}).Load("a","d"); !errors.Is(err,sentinel) { t.Fatalf("lost storage error: %v",err) }
}
func TestAccountErrors(t *testing.T) {
    tracker := app.Tracker(dispatchDB(nil))
    if _,err := tracker.Lookup(" ","d"); !errors.Is(err,model.ErrAccountRequired) { t.Fatal(err) }
    if _,err := tracker.Lookup("other","d"); !errors.Is(err,model.ErrNotFound) { t.Fatal(err) }
    for _, tc := range []struct{ account string; status int; message string }{{"",401,"account required"},{"other",404,"dispatch not found"}} {
        req := httptest.NewRequest("GET","/v1/dispatches/d",nil); req.Header.Set("X-Account",tc.account)
        w := httptest.NewRecorder(); app.Handler(dispatchDB(nil)).ServeHTTP(w,req)
        var body map[string]string; _ = json.Unmarshal(w.Body.Bytes(),&body)
        if w.Code != tc.status || body["error"] != tc.message { t.Fatalf("%d %s",w.Code,w.Body.String()) }
    }
}
