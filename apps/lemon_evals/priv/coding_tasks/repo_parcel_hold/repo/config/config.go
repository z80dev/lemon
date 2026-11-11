package config

import "os"

func StorePath() string {
    if path := os.Getenv("PARCEL_STORE"); path != "" { return path }
    return "parcels.json"
}
func Address() string {
    port := os.Getenv("PORT")
    if port == "" { port = "8080" }
    return ":"+port
}
