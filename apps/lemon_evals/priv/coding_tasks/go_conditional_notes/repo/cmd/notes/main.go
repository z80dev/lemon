package main

import (
	"example.com/go_conditional_notes"
	"log"
	"net/http"
)

func main() { log.Fatal(http.ListenAndServe(":8080", notes.NewHandler())) }
