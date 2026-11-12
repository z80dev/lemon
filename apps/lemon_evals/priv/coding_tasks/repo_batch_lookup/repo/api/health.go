package api

import "net/http"

func health(w http.ResponseWriter,r *http.Request) { respond(w,200,map[string]string{"status":"ok"}) }
