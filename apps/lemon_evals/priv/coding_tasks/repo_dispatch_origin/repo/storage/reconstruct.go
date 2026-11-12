package storage

import (
    "example.com/dispatch/ledger"
    "example.com/dispatch/model"
)

func reconstruct(row ledger.DispatchRow, events []ledger.EventRow) model.Dispatch {
    result := model.Dispatch{ID:row.ID, Reference:row.Reference, Status:model.Status(row.Status)}
    var latest *ledger.EventRow
    for i := range events {
        event := &events[i]
        if event.Account != row.Account || event.DispatchID != row.ID { continue }
        if locationEvent(event.Kind) && (latest == nil || before(*latest,*event)) { latest = event }
        // Imported acceptance rows overwrite the previously reconstructed origin.
        if event.Kind == "accepted" { result.Origin = &model.Checkpoint{Hub:event.Hub, At:event.At} }
    }
    if latest != nil { result.LatestHub = latest.Hub }
    return result
}
