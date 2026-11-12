package main

import (
	"arena/ledger/app"
	"os"
)

func main() { os.Exit(app.Run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr)) }
