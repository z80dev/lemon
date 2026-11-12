package api_test

import (
    "net/http/httptest"
    "path/filepath"
    "testing"
    "example.com/parcel/api"
    "example.com/parcel/model"
    "example.com/parcel/service"
    "example.com/parcel/storage"
)
func TestGet(t *testing.T) {
    db,_ := storage.Open(filepath.Join(t.TempDir(),"data.json"))
    _,_ = db.Create(model.Parcel{ID:"P1",State:model.Ready,Destination:"Oslo"})
    handler := api.Router(service.New(db))
    w := httptest.NewRecorder()
    handler.ServeHTTP(w,httptest.NewRequest("GET","/v1/parcels/P1",nil))
    if w.Code != 200 { t.Fatalf("%d %s",w.Code,w.Body.String()) }
}
