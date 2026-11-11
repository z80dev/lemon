package storage

import "example.com/parcel/model"

func (s *Store) Get(id string) (model.Parcel,error) {
    s.mu.Lock()
    defer s.mu.Unlock()
    value,ok := s.records[id]
    if !ok { return model.Parcel{},model.ErrNotFound }
    return fromRecord(value),nil
}
