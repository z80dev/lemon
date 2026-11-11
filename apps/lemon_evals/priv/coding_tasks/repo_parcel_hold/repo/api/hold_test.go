package api_test

import (
    "encoding/json"
    "net/http/httptest"
    "path/filepath"
    "strings"
    "testing"
    "example.com/parcel/api"
    "example.com/parcel/app"
    "example.com/parcel/model"
    "example.com/parcel/service"
    "example.com/parcel/storage"
)
func TestHoldSurvivesRestart(t *testing.T) {
    path := filepath.Join(t.TempDir(),"parcels.json")
    store,err := storage.Open(path); if err != nil { t.Fatal(err) }
    if _,err := store.Create(model.Parcel{ID:"P1",Destination:"Oslo",State:model.Ready,Revision:2}); err != nil { t.Fatal(err) }
    w := httptest.NewRecorder()
    api.Router(service.New(store)).ServeHTTP(w,httptest.NewRequest("POST","/v1/parcels/P1/hold",strings.NewReader(`{"reason":"  customs  "}`)))
    if w.Code != 200 { t.Fatalf("hold status=%d body=%s",w.Code,w.Body.String()) }
    desk,err := app.Open(path); if err != nil { t.Fatal(err) }
    w = httptest.NewRecorder()
    api.Router(desk).ServeHTTP(w,httptest.NewRequest("GET","/v1/parcels/P1",nil))
    var got map[string]any
    if err := json.Unmarshal(w.Body.Bytes(),&got); err != nil { t.Fatal(err) }
    hold,ok := got["hold"].(map[string]any)
    if w.Code != 200 || !ok || hold["reason"] != "customs" || got["revision"] != float64(3) { t.Fatalf("%d %#v",w.Code,got) }
    w = httptest.NewRecorder()
    api.Router(desk).ServeHTTP(w,httptest.NewRequest("DELETE","/v1/parcels/P1/hold",nil))
    if w.Code != 200 { t.Fatalf("release status=%d",w.Code) }
    desk,err = app.Open(path); if err != nil { t.Fatal(err) }
    w = httptest.NewRecorder()
    api.Router(desk).ServeHTTP(w,httptest.NewRequest("GET","/v1/parcels/P1",nil))
    if err := json.Unmarshal(w.Body.Bytes(),&got); err != nil { t.Fatal(err) }
    if got["hold"] != nil || got["revision"] != float64(4) { t.Fatalf("%#v",got) }
}
