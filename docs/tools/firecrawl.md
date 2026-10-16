# Firecrawl Fallback (`webfetch`)

`webfetch` can use Firecrawl as a fallback extractor when direct fetch/extraction fails.

## Quick Setup

```bash
export FIRECRAWL_API_KEY="fc-..."
```

```toml
[runtime.tools.web.fetch.firecrawl]
# If omitted, fallback is auto-enabled when an API key is present.
enabled = true
api_key = "fc-..."                    # or api_key_secret = "<secret name>", or FIRECRAWL_API_KEY
base_url = "https://api.firecrawl.dev"
only_main_content = true
max_age_ms = 172800000                 # 48h
timeout_seconds = 60
```

Key resolution order: `api_key` (or `LEMON_FIRECRAWL_API_KEY`), then the Lemon
secret named by `api_key_secret`, then `FIRECRAWL_API_KEY`. `LEMON_FIRECRAWL_BASE_URL`
and `LEMON_FIRECRAWL_ENABLED` (`true`/`1`/`yes`, `false`/`0`/`no`) override the
matching TOML keys. If `base_url` has no path, requests go to `/v2/scrape`.

## When Fallback Runs

By default `webfetch` tries the `direct` provider, then `firecrawl` when it is
enabled. Fallback is attempted when direct extraction fails due to network, HTTP,
or extraction errors.

Fallback is not attempted when the request is blocked by direct safety validation, such as:

- invalid/non-HTTP URL
- SSRF/private-network block
- `body_too_large` (response exceeds `max_body_bytes`)

A call can also name providers explicitly with `provider` and `fallbackProviders`
(for example `provider: "firecrawl"`); an explicit `provider` replaces the default
`direct`, `firecrawl` order.

## Operational Notes

- `enabled = false` disables fallback even if a key exists.
- `enabled = true` without an API key does not enable fallback.
- If `enabled` is omitted, fallback enables automatically when an API key is available.
- The returned payload sets `"extractor": "firecrawl"` when fallback is used.
- Firecrawl results are cached and truncated like other `webfetch` results; see
  [Web tools](web.md#full-content-after-truncation).

## Troubleshooting

- `Firecrawl fetch failed (<status>)`: Firecrawl returned a non-2xx response; 401/403 usually means an invalid or missing API key.
- `Firecrawl request failed`: network or DNS issue to `base_url`.
- Fallback never triggers: confirm it is enabled and has a key, and that failures are not SSRF/URL validation blocks.
