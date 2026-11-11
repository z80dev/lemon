# Client protocol

POST /v1/orders/lookup takes {"ids":["O1","O2"]} and responds with results.
Missing orders are data, not errors. GET /health returns {"status":"ok"}.
The command package also exposes cli.Run(ids, lookup, out), which emits the
same envelope as the HTTP lookup. Business failures produce no CLI output.
