package service

import (
    "strings"
    "example.com/dispatch/model"
)

type Repository interface { Find(account, id string) (model.Dispatch, error) }
type Tracker struct { repository Repository }
func New(repository Repository) *Tracker { return &Tracker{repository:repository} }
func (s *Tracker) Lookup(account, id string) (model.Dispatch, error) {
    account = strings.TrimSpace(account)
    if account == "" { return model.Dispatch{}, model.ErrAccountRequired }
    return s.repository.Find(account,id)
}
