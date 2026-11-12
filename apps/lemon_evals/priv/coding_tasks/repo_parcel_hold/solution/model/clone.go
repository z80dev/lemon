package model

func Clone(parcel Parcel) Parcel {
    if parcel.Hold != nil { value := *parcel.Hold; parcel.Hold = &value }
    return parcel
}
