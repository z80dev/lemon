# Web and Browser Tools

`websearch`, `webfetch`, and the `browser_*` tools are built-in
external-content tools:

- `websearch`: query registered providers. Bundled providers are Brave
  (default), Exa, Perplexity Sonar, keyless DuckDuckGo, and user-hosted SearXNG.
- `webfetch`: extract readable content through registered providers. Guarded
  direct extraction is the default and optionally falls back to Firecrawl.
- `browser_navigate`: navigate the supervised local browser session.
- `browser_tabs`, `browser_tab_open`, `browser_tab_activate`,
  `browser_tab_close`: enumerate and manage tabs through stable Chrome target
  IDs.
- `browser_snapshot`: inspect the current page as a compact DOM snapshot.
- `browser_get_content`: return text and optionally sanitized HTML from the current page.
- `browser_click`, `browser_type`, `browser_hover`, `browser_select_option`,
  `browser_upload_file`, `browser_download`, `browser_press`, `browser_scroll`, `browser_back`:
  interact with the current page, or an explicit `targetId`.
- `browser_wait_for_selector`: wait until a selector appears.
- `browser_evaluate`: evaluate a JavaScript expression in the current page and
  return untrusted JSON-serializable output.
- `browser_events`: return buffered console, dialog, page error, and request failure events.
- `browser_get_cookies`, `browser_set_cookies`, `browser_clear_state`: inspect,
  seed, or clear browser session state through the supervised browser context.
- `browser_screenshot`: save a screenshot as a local artifact and return metadata;
  pass `includeImage: true` when the model also needs to inspect the screenshot,
  or `sendToChannel: true` when the artifact should be sent back through the
  final Telegram/Discord answer path.
- `browser_analyze`: capture a managed screenshot and pass it through
  `media_analyze_image` in one supervised BEAM-owned operation.
- `browser_exec`: run a bounded BUA-style program of up to 25 typed browser
  actions; raw CDP steps require explicit developer mode.
- `computer_use`: capture and drive native apps through cua-driver with SOM,
  vision, or AX state and background-first input delivery.

## Search and extraction providers

Both web tools use `CodingAgent.Search.Provider` and the shared
capability-aware registry. Providers declare `search`, `extract`, or both.
Selection is ordered and deterministic: an explicit request provider is
attempted first, followed by the request's `fallbackProviders`; otherwise the
configured provider and fallback are used. Each result includes the
requested/used provider and a safe attempt summary.

Identical concurrent requests are single-flight. One supervised operation calls
the provider while other callers await the same result; successful results then
enter the existing bounded ETS and optional persistent cache. Providers run in
isolated, timeout-bounded processes, so an exception, exit, or slow provider can
fall through without crashing the agent turn. URL-policy failures from guarded
direct extraction are terminal and never fall back through a remote extractor.

| Provider | Capability | Setup |
|---|---|---|
| `brave` | search | `BRAVE_API_KEY` or `runtime.tools.web.search.api_key` |
| `exa` | search/highlights and batch extract | `EXA_API_KEY` or configured key |
| `perplexity` | search/answer | `PERPLEXITY_API_KEY`, `OPENROUTER_API_KEY`, or configured key |
| `duckduckgo` | keyless search | none |
| `searxng` | search | `runtime.tools.web.search.providers.searxng.base_url` |
| `direct` | extract | built in; guarded HTTP plus readability |
| `firecrawl` | extract | `FIRECRAWL_API_KEY` or configured key |

Extensions may register additional providers with `type: :search`; the module
must implement `CodingAgent.Search.Provider`. Built-ins win identifier
conflicts, and extension providers are removed during extension reload.

Browser tools use the backend-neutral `LemonBrowser` facade. The default
`:local` backend dispatches to `LemonBrowser.LocalServer`, an OTP-supervised
Node/Playwright helper; `:controller` dispatches only to an exactly bound,
authenticated controller. Unknown, unavailable, offline, or mismatched
backends fail closed and never switch browser identity or profile implicitly.
The local backend requires the browser node client to be built:

```bash
cd clients/lemon-browser-node
npm install
npm run build
```

Additional built-ins cover Browserbase (`browserbase`), Browser Use Cloud
(`browser_use`), Firecrawl hosted browser sessions (`firecrawl`), Camofox
REST/Firefox (`camofox`), and explicit local/public routing (`hybrid`). Hosted
backends require an exact Lemon `session_id`, create one provider session per
session/profile/run scope, attach the Node driver without launching a browser,
redact CDP authority from status, and release provider state on idle. Camofox
uses snapshot refs such as `@e5` as selectors. Hybrid requires
`LEMON_BROWSER_HYBRID_PUBLIC_BACKEND`; local/private URLs stay on its local
backend, public URLs use that configured backend, and provider failure never
falls back across identities.

`browser_exec` is the provider-neutral Browser Use Agent code-mode equivalent.
Its program is a bounded typed action list rather than arbitrary Python, so
Lemon can audit every navigation, input, evaluation, screenshot, and tab step.
Use `targetId = "$active"` to carry the prior tab result. A `cdp` step requires
`browser_developer_mode: true`; `Browser.close`, `Target.closeTarget`, and raw
download-policy mutation remain blocked.

`computer_use` drives native desktop apps through a lazily started private
`cua-driver` daemon in standard permission mode. Capture supports `som`,
`vision`, and `ax`; input supports element or coordinates, click variants,
drag, scroll, type, key/hotkey, value setting, app focus, and optional
post-action capture. Input defaults to `background`. Foreground focus is an
explicit escalation, capture artifacts follow browser retention, driver
session ids are derived hashes, and timeouts/errors are not automatically
replayed because the external effect may already have happened.

By default the helper launches local Chrome/Chromium and connects over CDP on
`127.0.0.1`. Set `LEMON_BROWSER_CDP_ENDPOINT` or pass `--cdp-endpoint` to the
local driver to attach to an already-running local or managed CDP endpoint
instead. Endpoint attach mode is attach-only: Lemon will not try to launch a
replacement browser if that endpoint is unreachable, and connection errors
redact endpoint credentials before surfacing to operators.

Every page-scoped browser tool accepts optional `targetId`. When omitted it
uses the session's active target; `browser_tab_activate` changes that active
target. `browser_tabs` returns stable real Chrome target IDs. Lemon separately
tracks browsers it launched and browsers it merely attached to; stopping an
attached session never sends `Browser.close` and never terminates the user's
browser.

### Existing signed-in Chrome via MV3

The opt-in extension relay exposes existing signed-in tabs without launching a
debugging profile:

```bash
export LEMON_BROWSER_RELAY_TOKEN="$(openssl rand -hex 32)"
./bin/lemon-browser-relay start
./bin/lemon-browser-relay install

export LEMON_BROWSER_CDP_ENDPOINT="ws://127.0.0.1:9224/cdp?token=$LEMON_BROWSER_RELAY_TOKEN"
export LEMON_BROWSER_ATTACH_ONLY=true
```

Load the directory printed by `install` through Chrome's **Load unpacked** UI,
then enter the same token and port in the extension settings. The relay binds
only to loopback, requires constant-time token authentication on discovery and
both WebSocket paths, hides restricted Chrome pages, and acknowledges rather
than forwards `Browser.close`. The extension displays connection state in its
badge and reconnects with bounded backoff. See
[`clients/lemon-browser-node/README.md`](../../clients/lemon-browser-node/README.md).

Remote controllers use `browser.controller.ticket`, `register`, `heartbeat`,
`result`, and `status`. Tickets are strong, short-lived, hashed at rest, and
single-use. Registration binds the authenticated principal, exact controller,
browser profile, Lemon session/run, and allowlisted capabilities. Each command
has bounded completion, and results are accepted only from the exact registered
WebSocket process. Controller-backend requests must supply the exact controller,
profile, and session binding; omitted identities never select the only available
controller implicitly. Offline, expired, replayed, mismatched, incomplete, or
under-capability requests fail closed.

Screenshots default to `.lemon/browser-artifacts/` under the active working
directory unless a `path` is provided.
By default, screenshot responses return only redacted metadata and a local
artifact path. `includeImage: true` adds a model-visible image content block for
the captured screenshot while keeping raw base64 out of result details.
`sendToChannel: true` adds redacted `auto_send_files` metadata pointing at the
local screenshot artifact; Telegram and Discord renderers can then deliver the
file as a real attachment on finalization.

`browser_analyze` is the one-step browser vision workflow. It captures the
current page as a managed screenshot artifact, analyzes that image through
`media_analyze_image` with `local_vision` or `openai_vision`, writes a managed
analysis artifact, and returns untrusted analysis text plus safe screenshot and
analysis metadata. Pass `includeImage: true` only when the model also needs the
raw screenshot pixels as an image block.

`browser_navigate` accepts an optional `route` guard: `auto`, `public`, or
`local`. The default `auto` keeps Lemon's local-first browser behavior and
classifies each target as public, private, or local-document before forwarding
to the browser worker. `public` rejects local/private/data/file targets, `local`
rejects public web targets, and cloud metadata endpoints are blocked before the
supervised worker in every route. The same `LemonBrowser.RoutePolicy`
guard is enforced by the control-plane `browser.request` proxy before it
dispatches `browser.navigate` to a paired node or local fallback; already
prefixed methods such as `browser.navigate` are passed through without
double-prefixing, and policy-only `route` args are stripped before node
dispatch. Progress updates include only safe route classification metadata plus
hashed host data, never the raw URL.

`browser_evaluate` is page-scoped JavaScript only. The evaluated value is
returned as untrusted tool output, while progress updates omit the expression
and only record that a sensitive argument was present.

`browser_upload_file` attaches one or more project-local files to a file input
selected by CSS selector. It accepts `path` for one file or `paths` for several,
validates every file under the current project before dispatch, uses the browser
worker's `browser.setInputFiles` method, and returns untrusted output. Progress
updates redact selectors and upload paths.

`browser_download` waits for the next browser download, optionally after
clicking a CSS selector. If `path` is omitted, Lemon saves the file under the
managed `.lemon/browser-artifacts/` directory using a sanitized suggested
filename; explicit `path` values must resolve under the current project and
must not point at an existing directory. The tool returns untrusted download
metadata including the saved path, suggested filename, and byte count. Progress
updates redact selectors, output paths, filenames, and downloaded file contents.

`browser_events` returns the latest buffered page-side events from the current
session. Pass `clear: true` to drain the buffer after reading it. Dialog events
are dismissed by the browser helper after they are recorded so they do not block
later page actions.

`browser_get_cookies` accepts an optional `url` to scope the returned cookies
and redacts cookie values by default; pass `includeValues: true` only when raw
cookie values are needed for an explicit browser-state task.
`browser_set_cookies` accepts Playwright cookie objects. `browser_clear_state`
clears cookies, current-page `localStorage`/`sessionStorage`, and buffered
events by default; pass `clearCookies`, `clearStorage`, or `clearEvents` as
`false` to leave a specific state surface intact.

Control-plane operators can inspect the same BEAM-owned browser surface with
`browser.status`, including local driver status, request counters, the last
worker error, the artifact directory, and recent artifact cleanup metadata. The
status surfaces include a redacted driver config
summary showing local-CDP vs remote-CDP mode, attach-only state, launch behavior,
local CDP port, and an endpoint hash when a managed endpoint is configured.
`browser.status` also reports paired browser nodes.
Doctor support bundles include the same redacted metadata in
`browser_diagnostics.json`; screenshot bytes are not embedded in the bundle.
Browser artifacts are local files and screenshot writes now enforce managed
retention for the artifact directory: keep 14 days or the newest 100 files,
whichever retains fewer old artifacts.

Browser tools emit channel-safe partial progress updates into Lemon's normal
tool-status pipeline. The updates carry the browser method, phase, timeout,
safe result counts, artifact flags, and hashed host metadata where relevant;
they do not include raw URLs, selectors, evaluated expressions, typed text,
selected values, upload paths, download paths, filenames, uploaded or
downloaded file contents, cookie values, page text, screenshot bytes, or
artifact paths. Web, TUI, Telegram, and Discord status
surfaces can render these updates as browser child actions while the supervised
request is running.

The deterministic browser proof lives in
`apps/coding_agent/test/coding_agent/tools/browser_test.exs`. It drives a
local `data:` page through `browser_navigate`, `browser_snapshot`,
`browser_wait_for_selector`, `browser_evaluate`, `browser_hover`,
`browser_select_option`, `browser_upload_file`, `browser_download`,
`browser_type`, `browser_click`,
`browser_get_content`, `browser_events`, and the cookie/state control wrappers
using the supervised
`LemonBrowser.LocalServer` boundary, and checks browser progress update
redaction for URL, selector, upload-path, download-path, filename, and failure
paths.

The repeatable live local smoke runner is:

```bash
MIX_ENV=test mix run scripts/live_browser_smoke.exs
```

It launches the supervised local browser driver against Chrome/Chromium,
drives a local proof page through navigate, wait, evaluate, hover, select, upload,
download, snapshot, type, click, screenshot,
model-visible screenshot capture with `includeImage: true`, local
`media_analyze_image` analysis of that screenshot, one-step `browser_analyze`
local vision, route classification, metadata-endpoint blocking, public-route
guarding, attach-only CDP endpoint mode, content, event reads, cookie set/get,
and clear-state reset, writes screenshots under
`.lemon/browser-artifacts/`, and writes redacted proof JSON under
`.lemon/proofs/`. The proof includes progress update counts, method and phase
counts, browser child-action count, model-visible image hashes/counts plus local
vision analysis hashes/counts, `browser_analyze` hashes/counts, navigation route
and target-kind counts, blocked-navigation assertions, CDP attach completion,
`browser_upload_file_completed`, `browser_upload_file_count`,
`browser_download_completed`, `browser_download_bytes`, and redaction cleanup
assertions. Pass
`--executable` or set
`LEMON_BROWSER_EXECUTABLE` when Chrome/Chromium is not on `PATH`. Use
`LEMON_BROWSER_CDP_ENDPOINT` when the browser is already managed by another
local service, a container, or a remote CDP provider.

The real MV3/Chrome relay proof is:

```bash
cd clients/lemon-browser-node
npm run smoke:extension
```

It launches a disposable Chrome-for-Testing profile, loads the unpacked
extension, authenticates the loopback relay, enumerates existing tabs, opens a
new tab, reads title and DOM content through Playwright, detaches, and verifies
that the attached Chrome process remains alive. The smoke writes a redacted
`.lemon/proofs/browser-extension-smoke-latest.json` artifact; it persists no
relay token, loopback port, raw target ID, URL, or page content. Mocked
service-worker tests separately exercise the real toolbar-click opt-in/detach
state and debugger-event filtering.

The opt-in live model acceptance harness is:

```bash
mix run --no-start scripts/live_search_browser_leadership_smoke.exs
```

It starts real `CodingAgent.Session` turns on `openai-codex:gpt-5.6-luna` with
`:xhigh` reasoning, using isolated run-history and memory stores, a disposable
Chrome profile, and restricted trial-specific tool lists. It asserts ordered
SearXNG-to-DuckDuckGo fallback and multi-source synthesis, stable target-scoped
multi-tab reads, stale-target recovery, screenshot analysis, and refusal to
bypass an unpaired controller's consent/capability boundary. The latest and
archived results under `.lemon/proofs/search-browser-leadership-*.json` contain
only model/tool identifiers, counts, booleans, durations, and hashes—not
credentials, prompts, answers, URLs, target IDs, or tool result bodies.

## API Key Setup

Set keys in your shell or `.env` (autoloaded by Lemon startup scripts):

```bash
export BRAVE_API_KEY="..."
export PERPLEXITY_API_KEY="..."     # optional alternative to OPENROUTER_API_KEY
export OPENROUTER_API_KEY="..."      # optional alternative to PERPLEXITY_API_KEY
export FIRECRAWL_API_KEY="..."       # optional; used by webfetch fallback
```

Key resolution behavior:

- Brave search uses `runtime.tools.web.search.api_key`, then `BRAVE_API_KEY`.
- Exa uses `runtime.tools.web.search.providers.exa.api_key`, then `EXA_API_KEY`.
- Perplexity search uses `runtime.tools.web.search.perplexity.api_key`, then `PERPLEXITY_API_KEY`, then `OPENROUTER_API_KEY`.
- Firecrawl uses `runtime.tools.web.fetch.firecrawl.api_key`, then `FIRECRAWL_API_KEY`.

## Config Example

```toml
[runtime.tools.web.search]
enabled = true
provider = "brave"                    # "brave" | "perplexity" | "duckduckgo" | "searxng"
max_results = 5
timeout_seconds = 30
cache_ttl_minutes = 15

[runtime.tools.web.search.failover]
enabled = true
provider = "perplexity"

[runtime.tools.web.search.perplexity]
api_key = "<perplexity-api-key>"
# base_url can be omitted; Lemon auto-selects Perplexity vs OpenRouter by key source/prefix.
model = "perplexity/sonar-pro"

[runtime.tools.web.search.providers.searxng]
base_url = "https://search.example.com"

[runtime.tools.web.fetch]
enabled = true
max_chars = 50000
timeout_seconds = 30
cache_ttl_minutes = 15
max_redirects = 3
readability = true
allow_private_network = false
allowed_hostnames = []

[runtime.tools.web.fetch.firecrawl]
# If enabled is omitted, fallback auto-enables when api_key exists.
enabled = true
api_key = "fc-..."
base_url = "https://api.firecrawl.dev"
only_main_content = true
max_age_ms = 172800000
timeout_seconds = 60

[runtime.tools.web.cache]
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
- Global cache settings live under `runtime.tools.web.cache`.
- `runtime.tools.web.cache.max_entries` defaults to `100` entries per tool.
- `runtime.tools.web.cache.persistent = true` persists cache to disk across restarts.
- `runtime.tools.web.cache.path` defaults to `~/.lemon/cache/web_tools`.
- Cache hits include `"cached": true` in tool output.

## Troubleshooting

- `missing_brave_api_key`: set `BRAVE_API_KEY` or `runtime.tools.web.search.api_key`.
- `missing_perplexity_api_key`: set `PERPLEXITY_API_KEY` or `OPENROUTER_API_KEY` (or config key).
- `freshness is only supported by the Brave websearch provider`: remove `freshness` when using `provider = "perplexity"`.
- `Invalid URL: must be http or https`: use a valid HTTP(S) URL.
- `Blocked hostname` / `resolves to private/internal IP`: target is blocked by SSRF guards; use safer public host, or explicitly allow only what you trust.
- `Web fetch failed ... (Firecrawl fallback failed ...)`: verify `FIRECRAWL_API_KEY`, `base_url`, and network reachability.
- `Local browser driver not built`: run `npm install && npm run build` in
  `clients/lemon-browser-node`.
- `Could not find Chrome/Chromium executable`: install Chrome/Chromium or set
  `LEMON_CHROME_EXECUTABLE`.
- `browser.status` shows `last_error`: inspect that message first, then rerun
  `mix lemon.doctor --bundle` if you need a support artifact.

For Firecrawl-specific behavior, see [`docs/tools/firecrawl.md`](firecrawl.md).
