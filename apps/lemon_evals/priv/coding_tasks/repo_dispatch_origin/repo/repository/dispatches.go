package repository

import "example.com/dispatch/model"

type Loader interface { Load(account, id string) (model.Dispatch, error) }
type Dispatches struct { loader Loader }
func New(loader Loader) *Dispatches { return &Dispatches{loader:loader} }
func (r *Dispatches) Find(account, id string) (model.Dispatch, error) { return r.loader.Load(account,id) }
