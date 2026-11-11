package seed

import (
    "time"
    "example.com/dispatch/ledger"
)
func Demo() *ledger.Memory {
    db := ledger.New()
    db.Put(ledger.DispatchRow{Account:"north",ID:"D-100",Reference:"PO-71",Status:"in_transit"})
    start := time.Date(2026,4,8,9,0,0,0,time.UTC)
    db.Append(ledger.EventRow{Account:"north",DispatchID:"D-100",Kind:"accepted",Hub:"BOS",At:start,Sequence:1})
    db.Append(ledger.EventRow{Account:"north",DispatchID:"D-100",Kind:"moved",Hub:"NYC",At:start.Add(time.Hour),Sequence:2})
    db.Append(ledger.EventRow{Account:"north",DispatchID:"D-100",Kind:"accepted",Hub:"NYC",At:start.Add(2*time.Hour),Sequence:3})
    return db
}
