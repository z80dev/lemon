package main

import (
    "flag"
    "fmt"
    "os"
    "example.com/parcel/app"
    "example.com/parcel/cli"
    "example.com/parcel/config"
)
func run() error {
    path := flag.String("store",config.StorePath(),"snapshot path")
    flag.Parse()
    desk,err := app.Open(*path)
    if err != nil { return err }
    return cli.Run(flag.Args(),desk,os.Stdout)
}
func main() {
    if err := run(); err != nil { fmt.Fprintln(os.Stderr,err); os.Exit(1) }
}
