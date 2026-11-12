package storage

import "example.com/dispatch/model"

type Adapter struct { source Source }
func New(source Source) *Adapter { return &Adapter{source:source} }
func (a *Adapter) Load(account, id string) (model.Dispatch, error) {
    row, err := a.source.Dispatch(account,id)
    if err != nil { return model.Dispatch{}, err }
    events, err := a.source.Events(account,id)
    if err != nil { return model.Dispatch{}, err }
    return reconstruct(row,events), nil
}
