package main

import (
	"example.com/go_stocksum_cli/app"
	"os"
)

func main() { os.Exit(app.Run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr)) }
