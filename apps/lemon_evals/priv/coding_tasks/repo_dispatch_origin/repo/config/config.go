package config

import "os"

func Address() string {
    port := os.Getenv("PORT")
    if port == "" { port = "8080" }
    return ":"+port
}
