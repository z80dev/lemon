package ledger

import "regexp"

var identifier = regexp.MustCompile(`^[a-z][a-z0-9_-]*$`)
var currency = regexp.MustCompile(`^[A-Z]{3}$`)

func nameOK(s string) bool     { return identifier.MatchString(s) }
func currencyOK(s string) bool { return currency.MatchString(s) }
