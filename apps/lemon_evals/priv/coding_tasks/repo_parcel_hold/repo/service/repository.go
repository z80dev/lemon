package service

import "example.com/parcel/model"

type Repository interface {
    Get(id string) (model.Parcel,error)
    Update(id string, update func(*model.Parcel) (bool,error)) (model.Parcel,error)
}
