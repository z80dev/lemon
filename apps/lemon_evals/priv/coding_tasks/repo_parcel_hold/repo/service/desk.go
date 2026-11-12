package service

type Desk struct { repository Repository }
func New(repository Repository) *Desk { return &Desk{repository:repository} }
