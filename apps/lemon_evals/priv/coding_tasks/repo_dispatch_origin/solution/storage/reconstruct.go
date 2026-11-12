package storage

import (
    "example.com/dispatch/ledger"
    "example.com/dispatch/model"
)

func reconstruct(row ledger.DispatchRow, events []ledger.EventRow) model.Dispatch {
    result := model.Dispatch{ID:row.ID, Reference:row.Reference, Status:model.Status(row.Status)}
    var origin, latest *ledger.EventRow
    for i := range events {
        event := &events[i]
        if event.Account != row.Account || event.DispatchID != row.ID { continue }
        if locationEvent(event.Kind) && (latest == nil || before(*latest,*event)) { latest = event }
        if event.Kind == "accepted" && (origin == nil || before(*event,*origin)) { origin = event }
    }
    if origin != nil { result.Origin = &model.Checkpoint{Hub:origin.Hub, At:origin.At} }
    if latest != nil { result.LatestHub = latest.Hub }
    return result
}
