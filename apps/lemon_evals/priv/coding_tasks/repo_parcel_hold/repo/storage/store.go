package storage

import "sync"

type Store struct {
    mu sync.Mutex
    path string
    records map[string]record
}
func Open(path string) (*Store,error) {
    records,err := load(path)
    if err != nil { return nil,err }
    return &Store{path:path,records:records},nil
}
func (s *Store) candidate(id string, value record) map[string]record {
    next := make(map[string]record,len(s.records)+1)
    for k,v := range s.records { next[k]=v }
    next[id]=value
    return next
}
