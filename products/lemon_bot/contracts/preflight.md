# Bot origin and pairing preflight — v1

`preflight.ts` is the dependency-free TypeScript implementation, re-exported by
`@lemon-bot/sdk`. Mac/iOS implement the same predicate in their shared Apple kit;
this document is the wire contract for native and CLI consumers. All paths below
include `/v1`. This is product discovery, not controller `/ws` or Lemon Web health.

## Identity descriptors

`GET /v1/setup` is public, read-only and returns HTTP 200 `application/json`:

```json
{
  "product": "lemon_bot",
  "apiVersion": 1,
  "version": "0.1.0",
  "setupRequired": false,
  "instanceId": "78ff1076-c499-4fa2-8654-c03efc62c9ee",
  "publicUrl": "https://desktop.example.ts.net:8449",
  "capabilities": { "pairing": true }
}
```

The URL/UUID here are **illustrative, not a verified deployment address**. The
public projection contains no workspace ID/name, human identity, paths, controller
address, session, setup code or pairing proof. `capabilities.pairing` describes
implemented protocol support, not current owner consent or controller health.
An empty backend has `setupRequired:true`; it cannot be selected as a replacement
for an existing workspace just because it is reachable.

`GET /v1/identity` requires an existing enabled human **product session** and
returns `BackendIdentity`: the same descriptor **without** `setupRequired`, plus
`workspaceId:string`. An unauthenticated caller gets the ordinary 401 error
envelope; Bot/integration/operator credentials do not grant this access. Workspace
names and account identity still use existing authenticated resources.

`instanceId` is a random UUID created once in the product SQLite metadata. It
survives service restarts, workspace renames, public-origin/listener aliases and
controller changes; it is not a process, hostname, controller or UI installation
ID. Different fresh product databases have different IDs. Back up the database
with its ID. A restored copy retains that identity and must not be run as an
independent concurrent deployment. Corrupt persisted identity fails closed, not a
silent reset. Missing identity on upgrade is initialized once, transactionally.

## Required client predicate

1. Read `/identity` from the **already configured, authenticated** backend using
   its existing product session. Keep this expected `(instanceId,workspaceId)`.
   A Mac may read its configured loopback backend; the phone-advertised origin
   can be a different HTTPS alias of that same service. Never auto-create or
   auto-switch to an empty local backend on a probe failure.
2. Validate the candidate as an exact canonical scheme+authority: no userinfo,
   non-root path, trailing slash, query, fragment, whitespace or control chars.
   Physical-phone use requires HTTPS and rejects loopback/unspecified IPv4/IPv6,
   `localhost` (including `.localhost`/trailing-dot spellings) and mapped IPv4
   loopback. Noncanonical numeric host aliases are rejected rather than silently
   normalized. Explicit `same-machine` mode permits loopback HTTP for the local
   baseline or Simulator only; it is never an implicit fallback for phone use.
3. Use the platform's normal TLS/certificate validation. No trust-all delegate,
   insecure flag, `rejectUnauthorized:false`, runtime TLS bypass or overlay
   exception. Tailscale-looking DNS alone proves nothing. Check actual Tailscale
   install/login, same tailnet, ACL/listener/DNS, certificate and backend routing
   if unavailable. Preflight never provisions Serve, changes ports/routes, resets
   Serve, enables Funnel, launches a backend or starts a relay.
4. GET **exactly** `<candidate>/v1/setup` without credentials, cookies or pairing
   proof, with redirects refused, a 10-second overall deadline, no cache and a
   maximum 16 KiB JSON descriptor. Require HTTP 200, JSON media type, literal
   `product:"lemon_bot"`, `apiVersion:1`, nonempty bounded `version`/`instanceId`,
   boolean `setupRequired:false`, and `capabilities.pairing:true`. Arbitrary 200,
   controller health, HTML/redirects, old incomplete descriptors and especially
   `Phoenix.Router.NoRouteError` 404 from Lemon Web are **wrong service**, not
   successful reachability. Errors never include raw server bodies or secrets.
5. Require `setup.instanceId == expected.instanceId`, and independently validate
   `setup.publicUrl` as a phone-safe HTTPS origin. A reachable HTTPS candidate
   advertising localhost still fails. Network aliases need not have identical
   URL strings: **backend and workspace identity**, not hostname equality, bind
   them. Do not automatically follow an advertised URL or redirect.
6. Desktop/CLI may now check candidate `/identity` using the explicitly selected
   product session; require both IDs equal the authenticated baseline. The SDK
   `preflightBotOrigin({origin,expectedInstanceId,session:{token,workspaceId}})`
   performs both reads. Its `fetch` injection is a trusted platform/test seam,
   not permission to substitute an insecure transport. Runtime TLS-bypass flags
   are refused before dispatch.
7. The owner-issued QR/paste payload is **exactly four** singleton query keys:
   `lemonbot://pair?backend=<encoded-origin>&instance=<instanceId>&cluster=<workspaceId>&code=<one-use-code>`.
   Its parsed `PairingLink` is `{backendUrl,instanceId,workspaceId,pairCode}`.
   There is no three-key compatibility shim. Instance/workspace IDs come from
   the authenticated issuer backend, not a caller's chosen cluster/name. They
   are bounded opaque 1–128-character IDs; the one-use proof remains 43 ASCII
   base64url characters. All original link authority/length/encoding rules in
   [the pairing API](api.md#qr-format-review-and-trust) still apply.
8. The phone uses the QR's expected instance ID for public setup preflight
   **before** preview/claim. No desktop credential is sent to the phone. Keep the
   exact QR origin and expected IDs through pending state/restart. The secret-
   bound preview still supplies the workspace name and expiry for explicit
   review/Request connection. After connected completion, verify the returned
   auth workspace and authenticated `/identity` instance/workspace against the
   QR **before** installing credentials, showing Connected or synchronizing.
   `validateBotIdentity` implements that comparison. Public preflight alone
   returns `identity:null` and does **not** claim workspace verification.
9. Persist each client's own verified expected identity. On read-only reconnect,
   check both IDs again using that client's session; changed backend/workspace
   fails closed and preserves existing configuration/history. Identity mismatch
   never means silently accept a new server, issue credentials again or resend
   messages. Display explicit repair/re-pair instead.

These checks prove the API contract and identity on the selected TLS endpoint,
not physical-device reachability or synchronization. Real iPhone/Tailscale and
bidirectional workspace sync require separate operator-owned acceptance.

### Explicit initial-owner bootstrap

Ordinary pairing still requires `setupRequired:false`; it never accepts an empty
instance as an existing workspace. The trusted local backend operator command
`lemon-bot setup` instead reads the expected instance ID from the already existing
private DATA_DIR and invokes the **same** TypeScript preflight with
`setup:'required'`. That explicit mode requires `setupRequired:true` while keeping
every descriptor, identity, size, deadline, origin and TLS predicate above. It
does not authenticate or mint credentials. Native existing-workspace pairing
predicates are unchanged.

This command additionally requires the configured tailnet HTTPS origin to equal
the returned advertised origin (no alias selection/discovery at bootstrap).
`setup --print-origin` accepts either local configured/empty state, probes the
matching descriptor and writes only the verified origin; it never issues a proof.
Only explicit owner setup shows a separate five-minute sensitive proof directly
on the controlling terminal. No proof is sent in the preflight, origin, URL, QR,
argv or logs. The HTTP claim still uses the existing same-origin JSON `/v1/setup`
form/API, with expiry, attempt limits and atomic consumption; see the
[operator workflow](../backend/README.md#provider-free-owner-setup). There is no
provider/default-model precondition and no new bootstrap HTTP issuing endpoint.

## Pairing progress and uncertain outcomes

No new public socket, auth mechanism or credential-issuing endpoint is needed.
Existing `pairing.upserted` events publish committed safe states on authenticated
product realtime, only to the current issuing owner's desktop/web devices. Phone
sessions and other owners cannot observe them. Subscribe while the owner screen
is foreground; reconnect by cursor and reconcile exact `GET /pairings/:id`.
Headless owners without a registered desktop device use bounded GET polling
(e.g. every two seconds), stopping on terminal state, cancellation or the original
five-minute deadline. Newest-first `GET /pairings` remains bounded to 200 entries.

Before authentication, the phone observes `/pairings/:id/complete` privately with
**one saved fixed completion nonce** and the original claim token, no faster than
every two seconds, foreground only, until that same original deadline. Pending
reads do not approve or mint; approval alone creates exactly one bound device and
session. Completion progresses/reconciles that same receipt. Stop on
connected/denied/expired, interruption or cancellation; network/unknown outcomes
retain the fixed receipt and require reconciliation, never a new nonce or blind
reapproval. Original claim/issuance nonce replay remains bounded and proof-bound.

The backend binds outstanding pairing proof custody to the issuing instance ID;
a changed identity invalidates old requests. Fixed nonces, exact verification
code/device approval, explicit consent, single use, absolute expiry, encrypted
receipt custody and per-device revocation are otherwise unchanged. No pairing
URL, QR, claim token or session credential belongs in logs, output receipts,
screenshots, argv, history or analytics.

Focused checks: backend `bun test test/core/preflight.test.ts
test/core/pairing.test.ts test/core/accounts.test.ts`, `bun run typecheck`; SDK
`bun test test/pairing.test.ts`, `bun run check`. Native consumers also exercise
their platform TLS/transport and saved-identity tests.
