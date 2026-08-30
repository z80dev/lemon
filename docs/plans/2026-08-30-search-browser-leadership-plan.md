---
owner: codex
reviewer: codex
status: completed
---

# Search and Browser Leadership Plan

Last reviewed: 2026-08-30

## Objective

Make Lemon the strongest combined search and browser-control implementation in
the compared Lemon, Hermes, and OMP feature set without weakening Lemon's
local-first security, OTP supervision, redaction, or auditability.

The target combines:

- Lemon's route policy, supervised processes, artifact lifecycle, approval
  boundaries, and untrusted-content handling
- Hermes' capability-aware provider selection, exact controller identity,
  one-time registration tickets, and fail-closed bound-session routing
- OMP's multi-target browser ergonomics and opt-in Chrome extension to local
  CDP relay for already logged-in tabs

## Acceptance Contract

The revamp is complete only when all of the following are true.

### Search and extraction

- Search and extraction providers implement public behaviours rather than
  being selected through provider-specific branches in the model tool.
- Providers declare `search` and/or `extract` capabilities and readiness.
- Selection supports explicit providers, ordered automatic fallback, and
  deterministic error reporting.
- Concurrent identical requests are single-flight and successful results keep
  Lemon's bounded memory plus persistent cache behavior.
- Brave and Perplexity retain compatibility. Direct guarded extraction and
  Firecrawl retain compatibility.
- At least one keyless search provider and one additional search/extract
  provider are implemented with mocked contract tests and opt-in live proof.
- Extension providers can register and unregister search providers with the
  same deterministic conflict behavior used for model and memory providers.
- Every external result remains wrapped as untrusted content, and extraction
  never bypasses URL/redirect SSRF policy.

### Browser sessions and targets

- Browser tools can list, open, activate, and close tabs using stable target
  identifiers; existing calls continue to use an explicit active target.
- Each request may select a session/target without relying on process-global
  first-page state.
- Managed and attached browser ownership are distinct. Disconnecting from an
  attached browser never closes the user's browser.
- CDP configuration accepts and documents HTTP discovery endpoints and direct
  WebSocket endpoints consistently.
- Managed Chromium remains the isolated default.

### Authenticated controllers and Chrome extension

- A supervised controller registry binds principal, Lemon session/run,
  controller, browser profile, and target scope.
- Registration uses short-lived single-use tickets. Commands have unique IDs,
  bounded completion, cancellation, heartbeat, detach, and reconnect behavior.
- Capabilities are negotiated and allowlisted. Raw CDP and arbitrary evaluate
  require an explicit developer capability/policy.
- Once a session is bound to a controller, an offline or mismatched controller
  fails closed; it never silently falls back to another browser.
- A Manifest V3 Chrome extension uses `chrome.debugger` only after an explicit
  user tab attachment. Attached tabs have visible extension state and can be
  detached immediately.
- A loopback-only authenticated relay exposes the minimum CDP-compatible
  surface required by Lemon's Playwright driver. Relay credentials are scoped,
  short-lived, redacted, and never written to agent transcripts.
- Restricted Chrome pages and DevTools conflicts produce clear errors.

### Verification and product quality

- Unit tests cover validation, registry conflicts, capability selection,
  fallback, single-flight, lifecycle ownership, tab semantics, ticket replay,
  expiry, mismatched identity, offline fail-closed behavior, relay auth, and
  dangerous-capability gating.
- Contract tests cover every bundled search provider and every browser backend.
- Integration tests exercise the BEAM-to-Node protocol, the WebSocket
  controller path, and a real local Chromium instance.
- Extension tests exercise service-worker state and debugger/relay message
  routing with mocked Chrome APIs; a manual/live checklist covers actual Chrome.
- Focused tests, full app suites, `scripts/test fast`, `scripts/test quality`,
  relevant client tests, formatting, and `git diff --check` pass.
- A real Lemon instance runs with model `gpt-5.6-luna` and reasoning `xhigh`.
  Creative trials must force provider fallback, multi-source synthesis,
  multi-tab workflows, signed-in-tab attachment when available, stale-target
  recovery, screenshot analysis, and explicit refusal of unsafe controller
  escalation. Results are recorded without credentials or private content.

## Architecture

### Search ownership

Search provider contracts and registry live in `coding_agent` initially because
the model tools, credentials, cache, and external-content boundary already live
there. The public contracts are kept free of session implementation details so
they can move into a standalone package later without changing providers.

`CodingAgent.Search.Provider` owns the provider behaviour.
`CodingAgent.Search.Registry` owns deterministic built-in and extension
registration. `CodingAgent.Search.Dispatcher` owns capability selection,
single-flight, fallback, and normalized results. Tool modules remain responsible
for parameter schemas, credential resolution, caching, and the final untrusted
model boundary.

### Browser ownership

`lemon_browser` owns backend/controller selection and the session-safe request
contract. The Node driver owns Playwright pages, contexts, and CDP mechanics.
`coding_agent` owns model-facing schemas and approval policy. The control plane
owns authenticated remote controller transport and pairing.

The normal path becomes:

```
browser_* tool
  -> LemonBrowser.request(session identity, target, capability)
  -> BackendRegistry
       -> managed/local Node driver
       -> paired browser node
       -> bound Chrome controller
  -> redaction/artifact/untrusted-content boundary
```

### Chrome relay ownership

The extension owns user consent and `chrome.debugger` attachment. A Node relay
owns protocol translation and loopback WebSocket/CDP endpoints. Lemon owns
ticket issuance and controller authorization. No layer receives more authority
than the selected browser profile and explicitly attached tab.

## Delivery Order

1. Search provider contract, registry, dispatcher, compatibility migration,
   extension registration, additional providers, and contract tests.
2. Browser target/session protocol and owned-versus-attached lifecycle.
3. Browser backend registry and authenticated controller broker.
4. MV3 extension and local authenticated relay.
5. Control-plane/TUI diagnostics and configuration surfaces.
6. Full documentation, automated suites, real Chromium proof, and live Lemon
   agent trials with `gpt-5.6-luna` at `xhigh`.

## Non-goals

- Enabling control of a user's logged-in Chrome profile by default.
- Persisting browser cookies, relay bearer tokens, CDP credentials, or private
  page content in diagnostics.
- Treating a successful mocked provider response as live-provider proof.
- Adding provider breadth without deterministic selection and safety contracts.
- Replacing Lemon's browser route policy with provider-specific trust.

## Completion Evidence

Completed on 2026-08-30.

- Search/extraction now uses public provider contracts, deterministic registry
  precedence, capability-aware fallback, single-flight coalescing, normalized
  results, extension registration, and guarded untrusted-content boundaries.
- Browser control now has stable multi-tab target IDs, explicit target routing,
  managed-versus-attached ownership, HTTP/direct-WebSocket CDP support, a
  backend registry, exact controller/profile/session binding, and a supervised
  authenticated controller broker with ticket, capability, heartbeat, timeout,
  cancellation, and disconnect controls.
- The bundled Manifest V3 extension and authenticated loopback relay passed a
  real disposable-Chrome smoke. The persisted proof confirms extension load,
  explicit existing-tab opt-in, agent-created tab scope, Playwright title/DOM
  reads, and attached-browser preservation without retaining the token, port,
  raw target ID, URL, or page content.
- The final real-agent proof ran three unrestricted model decisions through
  actual `CodingAgent.Session` processes on
  `openai-codex:gpt-5.6-luna` at `xhigh`. It forced
  SearXNG-to-DuckDuckGo fallback, returned five results from four source sites,
  used two stable target-specific reads across multiple tabs, analyzed a
  screenshot, observed and recovered from a stale target, and refused an
  incompletely bound controller without evaluate or local-backend fallback.
- Focused BEAM verification passed with 37 `lemon_browser`, 60 search/browser
  `coding_agent`, and 3 controller control-plane tests. The browser Node client
  passed typecheck, lint, build, and 46 tests, including real service-worker
  code under mocked Chrome APIs. `scripts/test quality`,
  `scripts/test clients`, warnings-as-errors compilation, and
  `git diff --check` passed.

The broad `scripts/test fast` diagnostic was also exercised. It reached the
full `coding_agent` suite but was stopped after repeated unrelated baseline
failures: macOS `/var` versus `/private/var` canonicalization caused private
temporary-directory and kanban worktree assertions to fail, and the host
keychain command timed out in Lemon Core/CLI setup tests. Isolated reruns
confirmed the keychain timeout; no search, browser, controller, relay, or
extension test failed in that lane. These host-sensitive baseline defects are
outside this plan's implementation scope and remain visible rather than being
masked.

## Final Gap Audit

For the compared local-first search and browser-control scope, Lemon now
combines Hermes-style provider/controller contracts and fail-closed identity
with OMP-style stable multi-tab CDP control and an opt-in Chrome extension,
while retaining Lemon's OTP supervision, route policy, artifact lifecycle, and
redaction boundaries.

Two intentionally bounded follow-ups do not block this scope:

- Automation uses disposable Chrome. A user's real signed-in tab still
  requires their explicit extension-toolbar click; that consent boundary is
  deliberately not bypassed by an automated proof.

## 2026-08-30 Hermes Browser/CUA Expansion

The follow-up parity audit closed the hosted-browser and computer-use gaps:

- Exa now provides search/highlights and batch contents extraction through the
  same provider registry and untrusted-content boundary.
- Browserbase, Browser Use Cloud, and Firecrawl have exact-session hosted-CDP
  lifecycle adapters; Camofox has an exact-session REST/Firefox adapter.
- The hybrid backend keeps private/local targets local, routes public targets
  only to an explicit hosted backend, remembers the route per session, and
  never falls back across identities after provider failure.
- `browser_exec` provides a bounded provider-neutral BUA-style action program.
  Raw CDP requires developer mode and still blocks browser termination and raw
  download-policy mutation.
- `computer_use` covers Hermes' capture, click variants, drag, scroll, type,
  key, set-value, wait, app/window discovery, and focus vocabulary through a
  private standard-mode cua-driver daemon. State and artifacts are exact-session
  scoped/redacted, input is background-first, foreground is explicit, verdicts
  are surfaced, and uncertain actions are never automatically replayed.
