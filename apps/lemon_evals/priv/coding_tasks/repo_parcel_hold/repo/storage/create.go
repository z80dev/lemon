package storage

import "example.com/parcel/model"

func (s *Store) Create(parcel model.Parcel) (model.Parcel,error) {
    s.mu.Lock()
    defer s.mu.Unlock()
    if _,ok := s.records[parcel.ID]; ok { return model.Parcel{},model.ErrAlreadyExists }
    next := s.candidate(parcel.ID,toRecord(parcel))
    if err := save(s.path,next); err != nil { return model.Parcel{},err }
    s.records=next
    return model.Clone(parcel),nil
}
