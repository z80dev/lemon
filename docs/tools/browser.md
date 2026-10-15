# Browser Tool

`browser_*` tools let the agent drive a supervised browser session. The
model-facing tools live in `CodingAgent.Tools.Browser`
(`apps/coding_agent/lib/coding_agent/tools/browser.ex`); they call the
backend-neutral `LemonBrowser` facade in `apps/lemon_browser`. Page content,
evaluated output, and downloads are external content and are returned as
untrusted output. For the search/fetch tools and the shared web overview, see
[Web and Browser Tools](web.md).

## Enabling and configuration

The default `local` backend needs the Node driver built once:

```bash
cd clients/lemon-browser-node
npm install
npm run build
```

Environment variables read by `lemon_browser` (from
`apps/lemon_browser/lib/lemon_browser/env.ex`):

| Variable | Default | Purpose |
| --- | --- | --- |
| `LEMON_BROWSER_BACKEND` | `local` | Backend id: `local`, `controller`, `hybrid`, `browserbase`, `browser_use`, `firecrawl`, or `camofox`. |
| `LEMON_BROWSER_DRIVER_PATH` | unset | Path to the driver program. Otherwise `clients/lemon-browser-node/dist/local-driver.js` is used relative to the working directory. |
| `LEMON_BROWSER_CDP_ENDPOINT` | unset | CDP websocket endpoint to attach to instead of launching a browser. |
| `LEMON_BROWSER_ATTACH_ONLY` | `false` | Attach only; never launch a browser. |
| `LEMON_BROWSER_CDP_PORT` | `18800` | Local CDP port for a managed browser. Only positive integers are accepted. |
| `LEMON_BROWSER_HYBRID_LOCAL_BACKEND` | `local` | Backend for local/private targets under `hybrid`. |
| `LEMON_BROWSER_HYBRID_PUBLIC_BACKEND` | unset | Required under `hybrid`; backend for public targets. |
| `LEMON_BROWSER_RELAY_TOKEN` | unset | Shared secret for the loopback MV3 relay. Secret. |
| `LEMON_BROWSER_RELAY_PORT` | `9224` | Loopback port for the MV3 relay. |
| `BROWSERBASE_API_KEY` / `BROWSERBASE_PROJECT_ID` | unset | Browserbase hosted sessions. |
| `BROWSER_USE_API_KEY` | unset | Browser Use Cloud hosted sessions. |
| `FIRECRAWL_API_KEY` | unset | Firecrawl hosted browser sessions. |
| `CAMOFOX_URL` / `CAMOFOX_API_KEY` | unset | Camofox REST/Firefox server and optional bearer key. |
| `LEMON_CHROME_EXECUTABLE` | unset | Chrome/Chromium executable for the local driver, if it is not discovered automatically. |

The backend can also be selected with the application environment key
`:lemon_browser, :backend`; an explicit `backend:` option on
`LemonBrowser.request/4` overrides it.

Driver resolution failures are reported as `Local browser driver not built`
or `node executable not found on PATH` and remembered in driver status; the
supervision tree stays up.

## Backend selection

- `local` (default): launches local Chrome/Chromium and connects over CDP on
  `127.0.0.1`. With `LEMON_BROWSER_CDP_ENDPOINT` set, it attaches to that
  endpoint instead. Attach mode never launches a replacement browser, and
  stopping an attached session never closes the user's browser.
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
| `browser_analyze` | Screenshot the page and analyze it with a vision provider. | `provider` (`local_vision`, `openai_vision`), `prompt`, `responseFormat` (`json`, `text`), `detail`, `filename`, `includeImage`, `sendToChannel` |

Notes:

- `browser_navigate` route guard: `auto` (default) keeps local-first behavior;
  `public` rejects local, private, `data:`, and `file:` targets; `local` rejects
  public web targets. Cloud metadata endpoints are blocked on every route. The
  `route` argument is stripped before dispatch to the driver.
- `browser_screenshot` returns redacted metadata and the artifact path by
  default. `includeImage: true` adds a model-visible image block; `sendToChannel:
  true` marks the artifact for delivery through the Telegram/Discord final-answer
  path.
- `browser_analyze` returns the analysis text as untrusted output plus safe
  screenshot and analysis metadata. The `prompt` is stored only as redacted
  metadata.
- `browser_get_cookies` redacts values (`[redacted]`) unless `includeValues: true`.
- `browser_events` dialogs are dismissed by the helper after they are recorded.
- Raw CDP (`browser.cdp`) is not exposed to the model. At the driver layer it
  requires developer mode, and browser lifecycle and download-policy commands
  (`Browser.close`, `Target.closeTarget`, `Browser.setDownloadBehavior`,
  `Page.setDownloadBehavior`) are always blocked.

## Artifacts and file paths

- Screenshots and downloads are written under `.lemon/browser-artifacts/` in the
  active working directory unless a `path` is given.
- Download `path` and upload `path`/`paths` must resolve inside the current
  project. Upload sources must be existing regular files. A download output path
  must be a file path, not a directory.
- Artifacts are pruned by age and count: 14 days or the newest 100 files,
  whichever retains fewer old artifacts.

## Security notes

- Page output, evaluated values, events, and downloads are marked untrusted.
- Progress updates for the tool-status pipeline never include raw URLs, selectors,
  expressions, typed text, upload/download paths, filenames, cookie values, page
  text, or screenshot bytes; URLs appear only as hashed host metadata.
- Cookie values are redacted by default in results.
- Unknown, unavailable, or mismatched backends fail closed; a backend failure
  never switches browser identity or profile.
- Attached browsers are never closed by Lemon.
- The MV3 relay (`LEMON_BROWSER_RELAY_TOKEN`) binds to loopback only, requires
  the token on every connection, hides restricted Chrome pages, and ignores
  `Browser.close`. See the
  [browser node README](../../clients/lemon-browser-node/README.md).

## Troubleshooting

- `Local browser driver not built`: run `npm install && npm run build` in
  `clients/lemon-browser-node`, or set `LEMON_BROWSER_DRIVER_PATH`.
- `node executable not found on PATH`: install Node.js 24 LTS or later.
- `Could not find Chrome/Chromium executable`: install Chrome/Chromium or set
  `LEMON_CHROME_EXECUTABLE`.
- `browser navigation blocked metadata endpoint`: the target is a cloud metadata
  address; it is blocked on all routes.
- `browser_upload_file path must be under the current project` /
  `must be an existing file`: move the file into the project and pass a path to
  an existing file.
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
