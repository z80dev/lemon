package api_test

import (
    "encoding/json"
    "net/http/httptest"
    "testing"
    "example.com/dispatch/app"
    "example.com/dispatch/seed"
    "example.com/dispatch/view"
)
func TestDemoOrigin(t *testing.T) {
    req := httptest.NewRequest("GET","/v1/dispatches/D-100",nil)
    req.Header.Set("X-Account","north")
    w := httptest.NewRecorder()
    app.Handler(seed.Demo()).ServeHTTP(w,req)
    var value view.Dispatch
    if err := json.Unmarshal(w.Body.Bytes(),&value); err != nil { t.Fatal(err) }
    if w.Code != 200 || value.Origin == nil || value.Origin.Hub != "BOS" || value.LatestHub != "NYC" { t.Fatalf("status=%d value=%+v",w.Code,value) }
}
func TestUnknownAccount(t *testing.T) {
    req := httptest.NewRequest("GET","/v1/dispatches/D-100",nil)
    req.Header.Set("X-Account","south")
    w := httptest.NewRecorder()
    app.Handler(seed.Demo()).ServeHTTP(w,req)
    if w.Code != 404 { t.Fatalf("status=%d",w.Code) }
}
