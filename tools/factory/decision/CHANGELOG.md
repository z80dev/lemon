# Decision package changelog

## Unreleased

- Add a standalone, shadow-default OpenRouter `cloudflare/clef-flash` complexity
  classifier using the documented System One decision endpoint, with fail-closed
  catalog/protocol checks, fixed choices, bounded evidence/deadlines/retries,
  sanitized receipts and process-local single-flight caching.
- Resolve the existing OMP OpenRouter API key through its resolver over a
  read-only credential-store facade; keep secrets inside the HTTP helper.
- Add explicit policy/threshold/tier configuration, override-first pure routing
  selection, an offline agreement replay harness and deterministic mock tests.
  Existing factory routing and installed releases are intentionally unchanged.
