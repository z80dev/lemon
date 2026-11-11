package storage

import "example.com/dispatch/ledger"

type Source interface {
    Dispatch(account, id string) (ledger.DispatchRow, error)
    Events(account, id string) ([]ledger.EventRow, error)
}
