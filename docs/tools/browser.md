# Browser Tool

`browser_*` tools let the agent drive a supervised browser session. The
model-facing tools live in `CodingAgent.Tools.Browser`
(`apps/coding_agent/lib/coding_agent/tools/browser.ex`); they call the
backend-neutral `LemonBrowser` facade in `apps/lemon_browser`. Page content,
evaluated output, and downloads are external content and are returned as
untrusted output. For the search/fetch tools and the shared web overview, see
[Web and Browser Tools](web.md).

Truncated snapshots/page content include a session-scoped `artifact_uri` and
`artifactNotice` for the complete pre-character-truncation source. See
[full-content artifacts](web.md#full-content-after-truncation) for pagination,
scope and backend/storage requirements.

## Choosing a browser provider

Set one browser identity for Lemon in your config:

```toml
[runtime.tools.browser]
provider = "auto"
```

`LEMON_BROWSER_PROVIDER` overrides this setting. Providers are `auto`, `tern`,
`lcu`, `relay`, `local`, `cdp`, `browserbase`, `browser_use`, `firecrawl`,
`camofox`, `controller`, and `hybrid`. For an invocation bound to a local Tern
pane, `auto` first checks **Tern's native PiP browser**, then probes
**LCU → authenticated MV3 relay → managed local Chrome**. Other invocations
retain that latter order. Paid hosted providers are never selected automatically.
Set `runtime.tools.browser.tern = false` or `LEMON_BROWSER_TERN=0` to opt out.
Existing explicit legacy backend configuration remains supported.

If an auto-selected Tern PiP cannot open because its window is unavailable, its
browser operation is unsupported, or its daemon cannot connect, Lemon switches
to the next browser backend and includes a `providerNote` in the result. The
fallback is retained for the exact invocation; LCU is not a `browser_*` backend.
Other errors and errors after a successful open do not switch browser identity.

An explicit provider is **fail-closed**: missing prerequisites or a failed action
never silently switch to another provider, browser identity, or profile.
`lemon doctor` reports the requested provider, the selected provider (or
`unavailable`), and an actionable redacted reason. The control-plane `status`
browser subsystem uses the same read-only core resolver; neither diagnostic
starts a browser or installs anything.

A session's tool list resolves the provider once, and not at all when
`disabled`, `enabled_only` or the tool policy exclude every `browser_*` tool.
Tool descriptions name only the selected provider (on `browser_navigate`); the
detection reason appears in `lemon doctor`, control-plane `status`, and the error
a browser request returns when no provider is available.

With `lcu`, Chrome control is exposed through [`cua_js`](computer-use.md#chrome),
not the `browser_*` tool family. `lcu` is available only when native computer
use was enabled by its own explicit switch (`LEMON_COMPUTER_USE_ENABLED` /
`[runtime.tools.computer_use] enabled`) at boot; selecting `lcu` never enables
computer use, and with the switch off `auto` skips `lcu` and an explicit `lcu`
fails closed. LCU does not provide a browser-only mode, so that runtime also
exposes native app APIs under the existing app approval policy.
LCU must already be installed, its browser connector configured, and the relay
actively connected to Chrome. Installation or an enabled extension alone does
not establish readiness; auto-selection never runs setup. For local browser
tools, build the Node driver below. For `cdp`,
configure `LEMON_BROWSER_CDP_ENDPOINT`; for `relay`, configure the authenticated
MV3 relay and its token. Hosted providers require their corresponding credentials.

### LCU connector warning and rollback

**Before running `lcu browser install`, back up the existing native-messaging host
manifest(s) for `com.openai.codexextension` in the intended browser account.**
Installation repoints the official ChatGPT extension's native host at LCU's relay.
That account-level change can affect **Codex/ChatGPT Chrome control**, not just
Lemon. It does not install or enable the extension itself.

The installed LCU CLI source supports `lcu browser install` and `lcu browser status`;
it has **no browser revert/uninstall command**. To revert, restore the exact
pre-install native-host manifest backup so it again points to the original
Codex/ChatGPT host, then restart Chrome or toggle the extension. Without a backup,
use the official Codex/ChatGPT app's connector registration workflow to register
its own host again. Upstream LCU's removal guide also describes removing its
manifest and private relay copy, but deleting a manifest alone does **not**
restore an overwritten official host. See
[LCU installation/removal guidance](https://github.com/amontlabs/lcu/blob/main/docs/INSTALLATION.md).
Lemon never performs these changes for you.

## Enabling and configuration

The managed `local` provider needs Node.js 24 or later and Chrome/Chromium.
Release installs bundle the Node driver. A source checkout builds it once:

```bash
npm --prefix clients/lemon-browser-node install
npm --prefix clients/lemon-browser-node run build
```

`lemon doctor` reports which prerequisite is missing under `browser.provider`.

Environment variables read by `lemon_browser` (from
`apps/lemon_browser/lib/lemon_browser/env.ex`):

| Variable | Default | Purpose |
| --- | --- | --- |
| `LEMON_BROWSER_PROVIDER` | `auto` | Unified provider selection; see [Choosing a browser provider](#choosing-a-browser-provider). |
| `LEMON_BROWSER_BACKEND` | `local` | Backend id: `local`, `controller`, `hybrid`, `browserbase`, `browser_use`, `firecrawl`, or `camofox`. |
| `LEMON_BROWSER_DRIVER_PATH` | unset | Path to the driver program. Otherwise the driver bundled in a release (`lemon_browser` `priv/driver`) is used, then `clients/lemon-browser-node/dist/local-driver.js` under the source checkout (`LEMON_PATH`). The working directory is not searched. |
| `LEMON_BROWSER_CDP_ENDPOINT` | unset | CDP websocket endpoint to attach to instead of launching a browser. |
| `LEMON_BROWSER_ATTACH_ONLY` | `false` | Attach only; never launch a browser. |
| `LEMON_BROWSER_ALLOW_UNENFORCED_EGRESS` | `false` | Required to attach to a browser Lemon did not launch (CDP endpoint, attach-only, relay, or a Chrome already listening on the CDP port). Without it the driver refuses to attach. See "Egress enforcement". |
| `LEMON_BROWSER_CDP_PORT` | `18800` | Local CDP port for a managed browser. Only positive integers are accepted. |
| `LEMON_BROWSER_USER_DATA_DIR` | unset | Opt in to a dedicated managed Chrome user-data directory, using its cookies/logins. Default browser data directories are refused. |
| `LEMON_BROWSER_PROFILE_DIRECTORY` | unset | Profile inside that data directory, e.g. `Default` or `Profile 1`. |
| `LEMON_BROWSER_HYBRID_LOCAL_BACKEND` | `local` | Backend for local/private targets under `hybrid`. |
| `LEMON_BROWSER_HYBRID_PUBLIC_BACKEND` | unset | Required under `hybrid`; backend for public targets. |
| `LEMON_BROWSER_RELAY_TOKEN` | unset | Shared secret for the loopback MV3 relay. Secret. |
| `LEMON_BROWSER_RELAY_PORT` | `9224` | Loopback port for the MV3 relay. |
| `BROWSERBASE_API_KEY` / `BROWSERBASE_PROJECT_ID` | unset | Browserbase hosted sessions. |
| `BROWSER_USE_API_KEY` | unset | Browser Use Cloud hosted sessions. |
| `FIRECRAWL_API_KEY` | unset | Firecrawl hosted browser sessions. |
| `CAMOFOX_URL` / `CAMOFOX_API_KEY` | unset | Camofox REST/Firefox server and optional bearer key. A URL with embedded `user:password@` credentials is rejected; use `CAMOFOX_API_KEY`. |
| `LEMON_BROWSER_EXECUTABLE` | unset | Chrome/Chromium executable for the local driver, if it is not discovered automatically. |

The legacy backend can also be selected with the application environment key
`:lemon_browser, :backend`. Use the unified provider setting above to keep
diagnostics and model-facing tool availability consistent.

Managed profile settings also accept application config
`config :lemon_browser, user_data_dir: "/dedicated/chrome-data", profile_directory: "Profile 1"`;
the environment variables take precedence. Leave both unset to retain the
Lemon-owned profile. Stop the local browser before changing either setting:
an active driver refuses identity changes rather than reusing another profile.

Driver resolution failures are reported as `Local browser driver not found`
or `node executable not found on PATH` and remembered in driver status; the
supervision tree stays up.

## Backend selection

- `local`: launches managed local Chrome/Chromium and connects over CDP on
  `127.0.0.1`. Unified `local` selection (including `auto` choosing local)
  ignores attachment settings and does not attach to an existing browser.
- `tern`: drives a native browser PiP over the bound Tern pane through the
  daemon browser channel. It does not launch Chrome or use the Node driver.
- `cdp`: explicitly attaches to `LEMON_BROWSER_CDP_ENDPOINT`. It never launches
  a replacement browser, and stopping the session never closes the user's browser.
  Legacy backend overrides can retain their own attachment configuration; prefer
  the explicit `cdp` provider for consistent selection and diagnostics.
- `controller`: dispatches only to an authenticated controller bound to an exact
  controller, browser profile, session, and optional run. Tickets are single-use,
  short-lived, and carry an allowlisted capability set (`tabs`, `navigate`,
  `inspect`, `interact`, `evaluate`, `cookies`, `files`, `state`).
- `hybrid`: routes local/private URLs to `LEMON_BROWSER_HYBRID_LOCAL_BACKEND` and
  public URLs to `LEMON_BROWSER_HYBRID_PUBLIC_BACKEND`. It requires the public
  backend to be set.
- `browserbase`, `browser_use`, `firecrawl`: hosted CDP sessions, created lazily
  for an exact Lemon session/profile/run scope and released after idle time.
- `camofox`: Camofox REST/Firefox server. Snapshot refs such as `@e5` work as
  selectors.

Backend ids are fixed: a third-party backend can be registered, but it cannot
replace a built-in id.

## Native Tern operation

Tern owns the browser and its web identity; this is not the user's Chrome
profile or the MV3 relay. The Lemon session must carry its originating integer
pane binding. Browser availability requires both that binding and a successful
daemon handshake advertising `browser`; merely having `TERN_PANE` set is not
enough. `runtime.tools.browser.tern = false` disables integration, and
`LEMON_BROWSER_TERN=0` opts out through the environment.

Socket discovery is daemon-side only: `TERN_PANE_SOCKET`, then
`TERN_DAEMON_SOCKET`, then `TERN_CONFIG_DIR/daemon.sock`. On macOS the verified
default is `~/Library/Application Support/Tern/daemon.sock`. On Linux and other
platforms there is no guessed default: provide one of those daemon environment
settings or Tern remains unavailable. Tool arguments and invocation options
cannot supply a socket path. A connected daemon still needs native browser
support; headless/unsupported hosts return an explicit tagged error.

Each exact Lemon session/run/pane binding owns at most one PiP. Lemon opens
`about:blank`, finishes initial configuration, then navigates. Navigation and
tab-open URLs pass `RoutePolicy`, including the metadata-endpoint block.
`browser_tabs` lists window browser blocks; their decimal block IDs are
`targetId`s, not Chrome target IDs. Passing an existing undriven block's ID
adopts it. Switching a binding to another live block or stealing an already
driven block is refused.

Native snapshots preserve Tern refs for subsequent click, fill, press, hover,
and select actions. CSS click/hover resolve geometry in the isolated world and
send trusted mouse input; typing and page scrolling use trusted input. User
evaluation runs in the page world. Page-world instrumentation records console,
uncaught errors and resource failures alongside native navigation/dialog events;
like any page-world capture, the page can tamper with it. Events are bounded to
100 retained entries. Screenshots use native capture and the normal Lemon
artifact pipeline (paths, retention, `includeImage`, and channel delivery).

`browser_tab_close` closes an owned PiP, but **releases** an adopted block to the
user without closing it. Run completion, application shutdown, and idle expiry
perform the same ownership-aware cleanup. Idle expiry defaults to five minutes;
the internal `browser_idle_timeout_ms` option is capped at one hour.

Tern is not a CDP emulator. Raw CDP, history-back, uploads/downloads, cookie
management, state clearing, a second tab in the same binding, multi-value select,
and snapshot `interactiveOnly`/`includeText: false` return explicit
`unsupported` errors rather than simulated success. History-back is refused
because the daemon cannot expose its destination for pre-navigation route
validation. Native snapshot/act availability depends on the Tern platform build;
update Tern if these operations are unavailable.


## Action table

Every page-scoped action accepts an optional `targetId` (a stable Chrome target
ID from `browser_tabs`); without it the session's active tab is used. `timeoutMs`
defaults to 30000 and is capped at 120000 on every action.

| Tool | Purpose | Key parameters |
| --- | --- | --- |
| `browser_navigate` | Navigate to a URL. | `url` (required), `route` (`auto`, `public`, `local`) |
| `browser_tabs` | List tabs with stable target IDs and the active tab. | none |
| `browser_tab_open` | Open a tab and make it active. | `url` (default `about:blank`), `route` |
| `browser_tab_activate` / `browser_tab_close` | Activate or close a tab. | `targetId` (required) |
| `browser_snapshot` | Compact DOM snapshot with visible text and interactive elements. | `selector`, `maxChars`, `maxNodes`, `interactiveOnly`, `includeText` |
| `browser_get_content` | Page text and optionally sanitized HTML. | `includeText`, `includeHtml`, `maxChars`, `textMaxChars` |
| `browser_click` | Click an element. | `selector` (required) |
| `browser_type` | Type or fill text. | `selector`, `text` (required), `clear`, `useFill`, `delayMs` |
| `browser_hover` | Hover an element. | `selector` (required) |
| `browser_select_option` | Select values in a `<select>`. | `selector` (required), `value` or `values` |
| `browser_upload_file` | Attach project-local file(s) to a file input. | `selector` (required), `path` or `paths` |
| `browser_download` | Wait for a download, optionally after clicking. | `selector`, `path` (project-local file path) |
| `browser_press` | Press a key. | `key` (required, Playwright name), `selector` |
| `browser_scroll` | Scroll the page or bring a selector into view. | `selector`, `x`, `y`, `deltaX`, `deltaY`, `absolute` |
| `browser_back` | Go back in history. | none |
| `browser_wait_for_selector` | Wait until a selector appears. | `selector` (required) |
| `browser_evaluate` | Evaluate a JavaScript expression; output is untrusted JSON. | `expression` (required) |
| `browser_events` | Read buffered console, dialog, page error, and request failure events. | `limit`, `clear` |
| `browser_get_cookies` | Read cookies. Values are redacted unless requested. | `url`, `includeValues` |
| `browser_set_cookies` | Set Playwright cookie objects. | `cookies` (required) |
| `browser_clear_state` | Clear cookies, page storage, and buffered events. | `clearCookies`, `clearStorage`, `clearEvents` (all default `true`) |
| `browser_screenshot` | Save a screenshot as a local artifact. | `path`, `fullPage`, `type` (`png`, `jpeg`), `includeImage`, `sendToChannel` |
| `browser_analyze` | Screenshot the page and analyze it with a vision provider. | `provider` (`local_vision`, `openai_vision`), `prompt`, `model`, `responseFormat` (`json`, `text`), `detail` (`auto`, `low`, `high`), `maxRetries`, `filename`, `path`, `fullPage`, `type`, `includeImage`, `sendToChannel`, `sendScreenshotToChannel` |

Notes:

- `browser_navigate` route guard: `auto` (default) keeps local-first behavior;
  `public` rejects local, private, `data:`, and `file:` targets; `local` rejects
  public web targets. Hosts are classified after normalizing IP aliases
  (decimal/hex/octal, IPv4-mapped IPv6, trailing dot) and resolving DNS, with
  every answer checked; cloud metadata and link-local addresses are blocked on
  every route, and unresolvable hosts are refused. The driver repeats the
  metadata check before `navigate` and `tabOpen`. See "Egress enforcement"
  below for what is enforced per connection. The `route` argument is stripped before dispatch to the driver.
- `file:`, `data:` and `blob:` documents can expose local files.
  `browser_navigate` and `browser_tab_open` refuse them unless
  `allowLocalDocument: true` is passed. `browser_get_content`,
  `browser_snapshot`, `browser_screenshot` and `browser_analyze` refuse to read
  or capture a page whose current URL uses one of those schemes (including a
  page already open in the browser) without the same flag: the driver checks
  before capturing, and Lemon checks the returned page URL again before any
  content, image or artifact reaches the model or a vision provider.
  The flag makes these calls exec tier in tool policy, so they go through
  approval under the `ask` and `write` approval modes.
- `browser_screenshot` returns redacted metadata and the artifact path by
  default. `includeImage: true` adds a model-visible image block; `sendToChannel:
  true` marks the artifact for delivery through the Telegram/Discord final-answer
  path.
- Explicit file paths for `browser_screenshot`, `browser_analyze`,
  `browser_download` and `browser_upload_file`, and the default
  `.lemon/browser-artifacts` directory, must resolve inside the current project.
  The check resolves symlinks first (an in-project link to a file or directory
  outside the project is refused), refuses dangling symlinks and hard-linked
  files, and the tool then uses the resolved physical path. The one exception
  is an operator-configured artifacts directory (`:browser_artifacts_dir`),
  which is trusted configuration and may be outside the project; default
  screenshots and downloads then go there unchecked.
- `browser_analyze` returns the analysis text as untrusted output plus safe
  screenshot and analysis metadata. The `prompt` is stored only as redacted
  metadata. `sendToChannel` requests final-answer delivery of the analysis
  artifact; `sendScreenshotToChannel` requests delivery of the screenshot.
- `browser_get_cookies` redacts values (`[redacted]`) unless `includeValues: true`.
  Any value other than an explicit false (`false`, `"false"`, `0`, `"no"`, `""`)
  makes the call write tier, so raw values need approval under `ask` mode.
- `browser_events` dialogs are dismissed by the helper after they are recorded.
- Raw CDP (`browser.cdp`) is not exposed to the model. At the driver layer it
  requires developer mode, and the Node driver accepts only read-only methods
  that cannot start network traffic (`DOM.getDocument`, `DOM.querySelector`,
  `DOM.querySelectorAll`, `DOM.describeNode`, `DOM.getOuterHTML`,
  `DOM.getBoxModel`, `DOMSnapshot.captureSnapshot`,
  `Accessibility.getFullAXTree`, `Accessibility.getPartialAXTree`,
  `Page.getFrameTree`, `Page.getLayoutMetrics`, `Page.getNavigationHistory`,
  `Performance.getMetrics`, `Browser.getVersion`, `Target.getTargets`). Every
  other method, including `Page.navigate`, `Runtime.evaluate`,
  `Target.createTarget` and `Fetch.*`, is refused.

## Egress enforcement

- **Chrome launched by the Lemon driver** (the driver started the Chrome
  process itself in this session): the driver starts a loopback egress proxy
  first and launches Chrome with `--proxy-server` pointing at it and
  `--proxy-bypass-list=<-loopback>`, so loopback destinations are not silently
  exempted. The proxy resolves each destination itself, refuses it if any
  answer is a cloud metadata or link-local address, and connects to the IP it
  checked. HTTPS and `wss:` are tunnelled with CONNECT and never decrypted.
  Regression tests with real Chrome cover these transports, with zero
  connections reaching the forbidden destination: plain HTTP navigation,
  redirect hops, iframes, `window.open` popups, `tabOpen`, `fetch` from the
  page, `fetch` from a service worker, HTTPS via CONNECT, `ws:` and `wss:`
  WebSockets, and DNS rebinding between two requests. Other channels
  (WebRTC/UDP, QUIC, extension or browser-internal traffic) are not verified
  and must not be relied on. The driver also passes
  `--force-webrtc-ip-handling-policy=disable_non_proxied_udp`, but that is not
  verified either. Private-network destinations stay reachable through the
  proxy; the `public`/`local` route choice is enforced only by the
  `RoutePolicy` pre-check of the requested URL.
- Enterprise policies that override the command line (`ProxySettings`,
  `ProxyMode`, `WebRtcIPHandlingPolicy` and similar) are an unsupported
  configuration: they can remove the proxy, and Lemon does not detect this.
- **Every other browser is unprotected at egress**, so the driver refuses to
  attach to one unless the operator sets `LEMON_BROWSER_ALLOW_UNENFORCED_EGRESS=1`
  (or passes `--allow-unenforced-egress`). This covers an explicit `cdp`
  endpoint, `LEMON_BROWSER_ATTACH_ONLY`, the extension `relay`, and a Chrome
  that was already listening on the configured CDP port (even one a previous
  driver run launched). Hosted provider sessions (Browserbase, Browser Use,
  Firecrawl) set the opt-in themselves: their browsers egress from the
  provider's network, not this host. Camofox is a separate REST backend. With
  the opt-in, only the `RoutePolicy` and driver pre-checks of the requested
  `navigate`/`tabOpen` URL apply. Redirects, page scripts, subresources,
  workers and DNS changes are **not** filtered. Isolate such a browser at the
  network level.

## Artifacts and file paths

- Screenshots and downloads are written under `.lemon/browser-artifacts/` in the
  active working directory unless a `path` is given. That default directory gets
  the same physical project check as an explicit path.
- Exception: when the operator configures an artifacts directory
  (`:browser_artifacts_dir`), default screenshots and downloads are written
  there as given, even if it is outside the project. This is a trusted-config
  exception; explicit `path` arguments are still confined to the project.
- Explicit download `path` and upload `path`/`paths` must resolve inside the
  current project. Upload sources must be existing regular files. A download output path
  must be a file path, not a directory. The driver writes to the validated path
  exactly as given, and for a default download it reserves the file name with an
  exclusive create, so an existing entry (including a dangling symlink) is never
  reused.
- Artifacts are pruned by age and count: 14 days or the newest 100 files,
  whichever retains fewer old artifacts.

## Security notes

- Page output, evaluated values, events, and downloads are marked untrusted.
- Progress updates for the tool-status pipeline never include raw URLs, selectors,
  expressions, typed text, upload/download paths, filenames, cookie values, page
  text, or screenshot bytes; URLs appear only as hashed host metadata.
- Cookie values are redacted by default in results.
- Explicit, mismatched, and unavailable backends fail closed. Only the
  auto-selected Tern initial-open fallback described above switches identity.
- Attached browsers are never closed by Lemon.
- A selected managed profile runs actions **as the user**, with that profile's
  cookies, logins, and permissions. Only opt in profiles whose identity you intend
  to give the agent. Stopping Lemon closes only Chrome it launched; it never
  deletes, cleans, or rewrites the selected profile directory as part of shutdown.
  Chrome itself may persist normal browsing changes while running.
- Chrome 136+ ignores remote debugging on its default user-data directory.
  Lemon refuses platform-default Chrome/Chromium/Edge/Brave data directories
  (including symlink aliases). For your real logged-in browser, use the MV3
  relay below, or close Chrome and copy the desired profile to a dedicated
  non-default user-data directory before setting `LEMON_BROWSER_USER_DATA_DIR`.
- Profile locks fail closed: close Chrome using this profile, or attach via
  `LEMON_BROWSER_CDP_ENDPOINT` / relay. Lemon never removes profile locks.
- The MV3 relay (`LEMON_BROWSER_RELAY_TOKEN`) binds to loopback only, requires
  the token on every connection, hides restricted Chrome pages, and ignores
  `Browser.close`. See the
  [browser node README](../../clients/lemon-browser-node/README.md).
- CDP endpoints (relay token, hosted-provider session URLs) reach the driver
  only through its environment, never its argv, and no Lemon process keeps them
  in its state: a hosted session's driver is started with its endpoint and is
  not restarted with it later. Inline hosted-provider and Camofox API keys are
  held for the session's lifetime in a private credential store (so close,
  delete and idle cleanup authenticate as the session that created the remote
  state), configured keys are resolved from secrets when needed, and neither
  is kept in session or supervisor state. Provider URLs with embedded
  `user:password@` credentials are rejected. Driver errors and status remove
  userinfo and query values from URLs, and CDP connection failures name only
  the endpoint's scheme and host. The driver and any Chrome it launches do not
  inherit `LEMON_*` settings it does not use, relay/operator tokens, provider
  keys, or other `*TOKEN`/`*SECRET`/`*API_KEY` variables.

## Troubleshooting

- `Local browser driver not found`: reinstall Lemon (releases bundle the
  driver), set `LEMON_BROWSER_DRIVER_PATH`, or in a source checkout run
  `npm install && npm run build` in `clients/lemon-browser-node`.
- `The local browser driver could not be loaded` (doctor): the build predates
  the installed Lemon; reinstall, or rebuild `clients/lemon-browser-node`.
- `node executable not found on PATH`: install Node.js 24 LTS or later.
- `Could not find Chrome/Chromium executable`: install Chrome/Chromium or set
  `LEMON_BROWSER_EXECUTABLE`.
- `browser navigation blocked metadata endpoint`: the target (or one of its DNS
  answers or redirect hops) is a cloud metadata or link-local address; it is
  blocked on all routes.
- `browser navigation could not resolve host: <host>`: DNS returned no address;
  navigation fails closed.
- `browser_upload_file path must be under the current project` /
  `must be an existing file`: move the file into the project (not a symlink or
  hard link to a file elsewhere) and pass a path to an existing file.
- `browser_screenshot output path must be under the current project` /
  `path must be under the current project for browser_analyze`: pass a path
  inside the project, or omit `path` to use the managed artifact directory.
- `browser_download output path must be under the current project` /
  `must be a file path`: pass a file path inside the project, or omit `path`.
- `Browser request timed out`: raise `timeoutMs` (max 120000) or check that the
  page is reachable.
- Attach mode fails: confirm `LEMON_BROWSER_CDP_ENDPOINT` is reachable. Attach-only
  mode will not launch a replacement browser.
- Hybrid requests fail: set `LEMON_BROWSER_HYBRID_PUBLIC_BACKEND` to a configured
  hosted backend.
- Hosted backends fail: verify the matching API key variable and network access.
- `missing_browser_controller_binding`: a controller request is missing
  `controller_id`, `browser_profile_id`, or `session_id`.
