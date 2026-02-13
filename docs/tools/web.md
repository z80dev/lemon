# Web Tools (`websearch`, `webfetch`)

`websearch` and `webfetch` are built-in external-content tools:

- `websearch`: query the web with Brave (default) or Perplexity Sonar.
- `webfetch`: fetch a URL, extract readable content, and optionally fall back to Firecrawl.

## API Key Setup

Set keys in your shell or `.env` (autoloaded by Lemon startup scripts):

```bash
export BRAVE_API_KEY="..."
export PERPLEXITY_API_KEY="..."     # optional alternative to OPENROUTER_API_KEY
export OPENROUTER_API_KEY="..."      # optional alternative to PERPLEXITY_API_KEY
export FIRECRAWL_API_KEY="..."       # optional; used by webfetch fallback
```

Key resolution behavior:

- Brave search uses `agent.tools.web.search.api_key`, then `BRAVE_API_KEY`.
- Perplexity search uses `agent.tools.web.search.perplexity.api_key`, then `PERPLEXITY_API_KEY`, then `OPENROUTER_API_KEY`.
- Firecrawl uses `agent.tools.web.fetch.firecrawl.api_key`, then `FIRECRAWL_API_KEY`.

## Config Example

```toml
[agent.tools.web.search]
enabled = true
provider = "brave"                    # "brave" | "perplexity"
max_results = 5
timeout_seconds = 30
cache_ttl_minutes = 15

[agent.tools.web.search.failover]
enabled = true
provider = "perplexity"

[agent.tools.web.search.perplexity]
api_key = "pplx-..."
# base_url can be omitted; Lemon auto-selects Perplexity vs OpenRouter by key source/prefix.
model = "perplexity/sonar-pro"

[agent.tools.web.fetch]
enabled = true
max_chars = 50000
timeout_seconds = 30
cache_ttl_minutes = 15
max_redirects = 3
readability = true
allow_private_network = false
allowed_hostnames = []

[agent.tools.web.fetch.firecrawl]
# If enabled is omitted, fallback auto-enables when api_key exists.
enabled = true
api_key = "fc-..."
base_url = "https://api.firecrawl.dev"
only_main_content = true
max_age_ms = 172800000
timeout_seconds = 60

[agent.tools.web.cache]
persistent = true
path = "~/.lemon/cache/web_tools"
max_entries = 100
```

## Safety Notes (SSRF)

`webfetch` enforces URL/network guardrails by default:

- Only `http://` and `https://` URLs are allowed.
- Blocks local/internal targets (`localhost`, `.localhost`, `.local`, `.internal`, and private/internal IP ranges).
- Re-checks redirect targets on every hop.

Config knobs:

- `allow_private_network = true`: bypasses private-network blocking for most hosts. Cloud metadata endpoints (for example `metadata.google.internal` and `169.254.169.254`) remain blocked.
- `allowed_hostnames = ["internal.example"]`: host allowlist override for specific names.

## Caching Behavior and Defaults

`websearch` and `webfetch` cache through ETS plus optional disk persistence:

- Default `cache_ttl_minutes = 15` for both tools.
- `cache_ttl_minutes = 0` disables writes (effectively no caching).
- Global cache settings live under `agent.tools.web.cache`.
- `agent.tools.web.cache.max_entries` defaults to `100` entries per tool.
- `agent.tools.web.cache.persistent = true` persists cache to disk across restarts.
- `agent.tools.web.cache.path` defaults to `~/.lemon/cache/web_tools`.
- Cache hits include `"cached": true` in tool output.

## Troubleshooting

- `missing_brave_api_key`: set `BRAVE_API_KEY` or `agent.tools.web.search.api_key`.
- `missing_perplexity_api_key`: set `PERPLEXITY_API_KEY` or `OPENROUTER_API_KEY` (or config key).
- `freshness is only supported by the Brave websearch provider`: remove `freshness` when using `provider = "perplexity"`.
- `Invalid URL: must be http or https`: use a valid HTTP(S) URL.
- `Blocked hostname` / `resolves to private/internal IP`: target is blocked by SSRF guards; use safer public host, or explicitly allow only what you trust.
- `Web fetch failed ... (Firecrawl fallback failed ...)`: verify `FIRECRAWL_API_KEY`, `base_url`, and network reachability.

For Firecrawl-specific behavior, see [`docs/tools/firecrawl.md`](firecrawl.md).
