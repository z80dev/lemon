# Firecrawl Fallback (`webfetch`)

`webfetch` can use Firecrawl as a fallback extractor when direct fetch/extraction fails.

## Quick Setup

```bash
export FIRECRAWL_API_KEY="fc-..."
```

```toml
[agent.tools.web.fetch.firecrawl]
# If omitted, fallback is auto-enabled when api_key is present.
enabled = true
api_key = "fc-..."                    # or use FIRECRAWL_API_KEY
base_url = "https://api.firecrawl.dev"
only_main_content = true
max_age_ms = 172800000                 # 48h
timeout_seconds = 60
```

## When Fallback Runs

Fallback is attempted when the primary `webfetch` path fails due to network, HTTP, or extraction errors.

Fallback is not attempted when the request is blocked by direct safety validation, such as:

- invalid/non-HTTP URL
- SSRF/private-network block

## Operational Notes

- `enabled = false` disables fallback even if a key exists.
- If `enabled` is omitted, fallback enables automatically when an API key is available.
- Returned payload sets `"extractor": "firecrawl"` when fallback is used.

## Troubleshooting

- `Firecrawl fetch failed (401/403)`: invalid or missing API key.
- `Firecrawl request failed`: network or DNS issue to `base_url`.
- Fallback never triggers: confirm it is enabled and that failures are not SSRF/URL validation blocks.
