package ledger

type key struct { account, id string }
func rowKey(account, id string) key { return key{account:account, id:id} }
