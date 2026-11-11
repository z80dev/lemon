package service

import "example.com/parcel/model"

func (d *Desk) Show(id string) (model.Parcel,error) { return d.repository.Get(id) }
