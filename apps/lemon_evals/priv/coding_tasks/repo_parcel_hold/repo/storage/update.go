package storage

import "example.com/parcel/model"

func (s *Store) Update(id string, update func(*model.Parcel) (bool,error)) (model.Parcel,error) {
    s.mu.Lock()
    defer s.mu.Unlock()
    row,ok := s.records[id]
    if !ok { return model.Parcel{},model.ErrNotFound }
    parcel := fromRecord(row)
    changed,err := update(&parcel)
    if err != nil { return model.Parcel{},err }
    if !changed { return fromRecord(row),nil }
    next := s.candidate(id,toRecord(parcel))
    if err := save(s.path,next); err != nil { return model.Parcel{},err }
    s.records=next
    return model.Clone(parcel),nil
}
