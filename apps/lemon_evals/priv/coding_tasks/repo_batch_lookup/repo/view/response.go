package view

import "example.com/batchdesk/model"

type Response struct { Results []model.Result `json:"results"` }
func FromResults(results []model.Result) Response { return Response{Results:results} }
