package model

type Result struct {
    ID string `json:"id"`
    Found bool `json:"found"`
    Summary *Summary `json:"summary"`
}
type Summary struct {
    ID string `json:"id"`
    CustomerName string `json:"customer_name"`
    Lines []LineView `json:"lines"`
    TotalCents int64 `json:"total_cents"`
}
type LineView struct {
    SKU string `json:"sku"`
    Title string `json:"title"`
    Quantity int64 `json:"quantity"`
    UnitCents int64 `json:"unit_cents"`
    Available bool `json:"available"`
}
