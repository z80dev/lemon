package service

import (
    "strings"
    "unicode/utf8"
    "example.com/parcel/model"
)
func (d *Desk) PlaceHold(id, reason string) (model.Parcel,error) {
    reason = strings.TrimSpace(reason)
    length := utf8.RuneCountInString(reason)
    if length < 1 || length > 120 { return model.Parcel{},model.ErrInvalidReason }
    return d.repository.Update(id,func(p *model.Parcel) (bool,error) {
        if p.State.Terminal() { return false,model.ErrDelivered }
        if p.Hold != nil {
            if p.Hold.Reason == reason { return false,nil }
            return false,model.ErrAlreadyHeld
        }
        p.Hold = &model.Hold{Reason:reason}
        p.Revision++
        return true,nil
    })
}
func (d *Desk) ReleaseHold(id string) (model.Parcel,error) {
    return d.repository.Update(id,func(p *model.Parcel) (bool,error) {
        if p.Hold == nil { return false,nil }
        p.Hold=nil
        p.Revision++
        return true,nil
    })
}
