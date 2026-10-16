# LemonBrowser

Browser capability driver for agents: a supervised local browser session, the
guardrails that decide where it is allowed to go, and a view of the files it
leaves behind.

`lemon_browser` is one of the packages that make up the [Lemon](https://github.com/z80dev/lemon)
agent platform. Its only Lemon dependency is `lemon_core`.

## What is in it

| Module | Purpose |
|---|---|
| `LemonBrowser` | Backend-neutral request/status facade |
| `LemonBrowser.Backend` | Contract for local, paired-node, and controller backends |
| `LemonBrowser.BackendRegistry` | Built-in-safe runtime backend registry |
| `LemonBrowser.CloudSession` | Exact-session hosted CDP lifecycle and attach-only driver ownership |
| `LemonBrowser.CamofoxSession` | Exact-session Camofox REST/Firefox adapter |
| `LemonBrowser.HybridRouter` | Per-session local/private versus public-provider route memory |
| `LemonBrowser.LocalServer` | Supervised driver process: `request/3`, `status/0`, `stop/1` |
| `LemonBrowser.ControllerBroker` | Single-use controller tickets, exact identity binding, capability checks, timeouts |
| `LemonBrowser.RoutePolicy` | Navigation classification and guardrails: `validate_navigation/2`, `safe/1` |
| `LemonBrowser.Artifacts` | Metadata over saved artifacts: `recent/1`, `summary/1`, `cleanup/1` |
| `LemonBrowser.Env` | The app's environment-variable registry, aggregated by `LemonCore.Env` |

## Installation

`lemon_browser` is an app in the Lemon umbrella, not a Hex package; it ships as
part of the reference runtime. Starting the application starts `LemonBrowser.LocalServer` under
`LemonBrowser.Supervisor`; no other wiring is required.

Attached-machine capability inspection uses the internal
`LemonBrowser.LocalServer.inspection_config/1` seam. It obtains the configured
driver/attach policy without starting the driver or browser. This private config
may contain endpoint credentials and must never become an RPC result or log.
The execution-node inspector sends it only over a bounded local helper's stdin,
imports the installed driver's actual executable/discovery logic, and checks an
existing CDP HTTP/WebSocket endpoint passively. It never launches Chrome, opens
tabs, runs CDP commands or asks for browser permissions. Only bounded availability
booleans/reason classifications leave the worker; missing inspection is unknown,
not a fabricated permission grant.


## Driving a browser

```elixir
{:ok, result} = LemonBrowser.request("browser.navigate", %{"url" => "https://hex.pm"})
```

`request/3` takes a method name, a map of arguments and an optional timeout in
milliseconds (default `30_000`), and answers `{:ok, result}` or
`{:error, reason}`. Requests are multiplexed over one helper process: each one
carries an id, and a request that outlives its timeout answers
`{:error, "Browser request timed out"}` without disturbing the others.

`LemonBrowser.LocalServer.status/0` reports whether the driver is available and
running, the pending/completed/failed counts, the last error, and the resolved
driver configuration.

`LemonBrowser.request/4` is the public, backend-neutral entrypoint. It uses the
unified browser provider (default `auto`) or an explicit internal `backend:`
option. Explicit selections fail closed instead of switching browser identity
or profile. When LCU is selected, Chrome is exposed through `cua_js`, not this
facade. See [Choosing a browser provider](../../docs/tools/browser.md#choosing-a-browser-provider).
Runtime packages can implement `LemonBrowser.Backend` and register it with
`LemonBrowser.BackendRegistry`; built-in backend IDs cannot be replaced.

Built-ins are `local`, `controller`, `hybrid`, `browserbase`, `browser_use`,
`firecrawl`, and `camofox`. Hosted CDP sessions are created lazily, attached by
the Node/Playwright driver in attach-only mode, scoped to the exact Lemon
session/profile/run, and explicitly released after bounded idle time. The
hybrid backend requires an explicit public backend and never treats a hosted
failure as permission to fall back to a different local identity.

When evaluation enables the core native-process ledger, the local driver is
tracked before execution. Browser dispatch is separately recorded as uncertain:
attached browsers and hosted sessions are not contained by the driver's process
group, and a request error does not prove that external work never started.
Authorization and unavailable-backend refusals happen before that dispatch record.

## Vetting a URL first

```elixir
{:ok, policy} = LemonBrowser.RoutePolicy.validate_navigation("https://hex.pm", "public")
# => %{route: "public", effective_route: "public", target_kind: "public_network",
#      scheme: "https", private: false, metadata: false}

{:error, "browser navigation blocked metadata endpoint"} =
  LemonBrowser.RoutePolicy.validate_navigation("http://169.254.169.254/latest/meta-data")
```

Routes are `"auto"` (the default), `"public"` (public http(s) only) and
`"local"` (local documents and private-network addresses only). Cloud metadata
endpoints are refused on every route. `safe/1` reduces a policy to a
camelCased map with nil/false entries dropped, suitable for returning to a
caller or writing to a log.

This module is pure and does not touch the driver, so it can be used on its own
to vet URLs before handing them to any browser automation.

## The Node driver, and what happens without it

The helper process is a Node program that speaks a line-delimited JSON protocol
over stdin/stdout — one JSON object per line:

```
request:  {"id": "...", "method": "browser.navigate", "args": {...}, "timeoutMs": 30000}
response: {"id": "...", "ok": true, "result": {...}}
```

**The driver is not shipped in this package.** It is resolved from
`LEMON_BROWSER_DRIVER_PATH`, and otherwise from
`clients/lemon-browser-node/dist/local-driver.js` relative to the current
working directory, which is the Lemon monorepo's layout. Outside that monorepo,
point `LEMON_BROWSER_DRIVER_PATH` at a driver implementing the protocol above.

Absence degrades rather than crashes. The port is opened lazily on the first
request, so an application that never drives a browser never spawns anything.
If `node` is missing, or the driver path does not resolve, `request/3` answers
`{:error, "node executable not found on PATH"}` or
`{:error, "Local browser driver not built..."}`, the error is remembered in
`status/0`, and the supervision tree stays up. If a running helper exits, only
the requests in flight fail; the next request starts a fresh one.

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `LEMON_BROWSER_PROVIDER` | `auto` | Unified provider selection (`auto`, `lcu`, `relay`, `local`, `cdp`, or a configured hosted/backend ID) |
| `LEMON_BROWSER_DRIVER_PATH` | — | Path to the driver program |
| `LEMON_BROWSER_CDP_ENDPOINT` | — | CDP websocket endpoint to attach to instead of launching a browser |
| `LEMON_BROWSER_ATTACH_ONLY` | `false` | Only attach to an existing browser, never launch one |
| `LEMON_BROWSER_CDP_PORT` | `18800` | Local CDP port for a managed browser (positive integers only) |
| `LEMON_BROWSER_RELAY_TOKEN` | — | Required shared secret for the loopback MV3 extension/CDP relay |
| `LEMON_BROWSER_RELAY_PORT` | `9224` | Loopback MV3 relay port |
| `LEMON_BROWSER_BACKEND` | `local` | Built-in browser backend id |
| `LEMON_BROWSER_HYBRID_LOCAL_BACKEND` | `local` | Hybrid route for local/private targets |
| `LEMON_BROWSER_HYBRID_PUBLIC_BACKEND` | — | Required hybrid route for public targets |
| `BROWSERBASE_API_KEY` / `BROWSERBASE_PROJECT_ID` | — | Browserbase hosted sessions |
| `BROWSER_USE_API_KEY` | — | Browser Use Cloud hosted sessions |
| `FIRECRAWL_API_KEY` | — | Firecrawl hosted browser sessions |
| `CAMOFOX_URL` / `CAMOFOX_API_KEY` | — | Camofox REST/Firefox server |

### Existing signed-in Chrome

The bundled Manifest V3 extension and relay are documented in
[`clients/lemon-browser-node/README.md`](../../clients/lemon-browser-node/README.md).
The relay lets Lemon use opted-in existing Chrome tabs and authenticated
sessions without launching Chrome with a debugging profile. It is token-gated
by default and ignores `Browser.close` so an attached agent cannot terminate
the user's browser.

## Raw CDP

`LemonBrowser.request/4` accepts a raw `browser.cdp` method only when the caller
passes `developer_mode: true`; browser lifecycle and download-policy commands
(`Browser.close`, `Target.closeTarget`, `Browser.setDownloadBehavior`,
`Page.setDownloadBehavior`) remain blocked even then. No model-facing tool
issues raw CDP.

## Artifacts

Screenshots and other files a session saves default to
`<project_dir>/.lemon/browser-artifacts`; `:dir` overrides the directory and
`:project_dir` moves it. `recent/1` lists metadata (name, path, bytes,
modification time) newest-first, up to `:limit` entries (default 20, capped at
100). `summary/1` reports the count, total bytes and the age boundaries
alongside the retention policy in force. `cleanup/1` prunes by age and count,
defaulting to 14 days and 100 files, and reports what it removed.
