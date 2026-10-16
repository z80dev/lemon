# Phone and provider acceptance preparation

This is preparation, not physical-device or provider evidence. Keep F-0074 and
F-0080 operator-owned `needs_input` until actual evidence is recorded; do not
create replacement acceptance tasks. Coordinate the existing F-0069/F-0075
onboarding work rather than implementing another login path.

## Read-only readiness

From the repository root, run with Bun:

```sh
bun products/lemon_bot/scripts/phone_preflight.ts
# Once the intended existing service's metadata location is known:
bun products/lemon_bot/scripts/phone_preflight.ts \
  --data-dir /absolute/private/product-data-directory \
  --local-origin http://127.0.0.1:4080 \
  --origin https://YOUR-MACHINE.YOUR-TAILNET.ts.net:UNUSED-OR-EXISTING-BOT-PORT
bun test products/lemon_bot/scripts/phone_preflight.test.ts
```

The first command is discovery, not a pass. Replace placeholders only with
operator-reviewed existing values. `--data-dir` must identify the **running**
Bot service's existing `product.sqlite`, not a fresh directory. The script opens
it read-only and queries only instance/workspace metadata; it never opens its
master key, private configuration, session rows or Keychain credentials. Do not
print service environments, complete process arguments or private configuration
to discover it. Obtain the data directory and listener from the existing service
owner's configuration review; do not launch a second backend.

Output includes allowlisted listener process names/PIDs/ports, sanitized existing
`tailscale serve status --json` root routes and upstream ports, public API probe
classifications, and Apple toolchain/signing-identity **counts**. Subprocess errors,
raw HTTP bodies, certificate names, secrets and pairing URLs are never forwarded.
A missing command or permission is a blocker, not proof that no service exists.
Nonzero exit means no trusted matching phone origin was verified. Exit zero means
host-side product-origin verification only, never phone/provider acceptance.
Without an explicit database baseline, a local `instance_mismatch` means the
endpoint still needs trusted identity comparison, not that it is accepted.

The script reuses the [shared Bot predicates](../../products/lemon_bot/contracts/preflight.md):
exact origin, trusted TLS, no redirects, JSON product/version/capability descriptor,
bounded responses and instance match. A phone candidate must be HTTPS `.ts.net`
and its advertised `publicUrl` must equal the candidate. HTML 200, Phoenix JSON
404, control-plane health and an open port are insufficient. In particular,
**8448 forwarding to 4080 is not evidence of Bot**: 4080 may belong to Phoenix
Web. Inspect the classification and listener process, not the port convention.

The public setup endpoint deliberately does not expose workspace identity. The
read-only database baseline identifies the canonical stored workspace but cannot
prove which account the clients use. Before pairing, use the existing signed-in
Mac **Connect iPhone → Check connection readiness** to verify authenticated
`GET /v1/identity` at the configured backend and the exact advertised tailnet
origin against that baseline. Do not paste a bearer token into diagnostic argv,
shell history or this runbook. Do not send product credentials to an unverified
origin. Record safe instance/workspace IDs, not tokens or raw responses.

No valid route? Stop. This task authorizes **no** Serve/Funnel, service, launchd,
sandbox, account or credential changes. A separately approved operator action
must first inspect existing routes, preserve every listener/path, choose an
unused listener if needed and target the actual Bot service. Never reset Serve
or overwrite another route. Re-run discovery after the approved change; never
invent a verified address.

## Source and installation prerequisites

This checkout contains F-0070's setup/identity endpoints and shared preflight,
F-0071's guided Mac flow, F-0072's iOS preview/approval flow, F-0073's CLI pairing,
and F-0078's provider-free `lemon-bot setup` / `--print-origin`. Reuse those paths.
`setup` is a mutation that can issue owner authority; this diagnostic never calls
it. `setup --print-origin` is the existing read-only configured-service discovery
path when its private environment is already correctly supplied.

Provider management API (F-0076), Codex device login (F-0077), and Providers UI
(F-0079) are outstanding code dependencies for the second checklist. Recheck
merge availability at execution time; missing code is not a signing/network error.
Do not substitute CLI credentials, fake login or another onboarding implementation.

See the [Apple build guide](../../products/lemon_bot/apple/README.md) for the
canonical packaging/signing instructions and metadata in `apple/project.yml`.
Requirements: Xcode 26.3, XcodeGen 2.46+, Metal toolchain, package dependency
access; macOS 14+ and iOS 17+. Physical iOS requires an operator-controlled team,
registered app/share identifiers (`org.lemonbot.ios`, `org.lemonbot.ios.share` by
default), matching profiles, App Group `group.org.lemonbot.shared`, appropriate
APNs environment and a trusted device/install channel. A signing identity count
alone proves none of these bindings. Mac Debug ad-hoc signing is distinct from
provisioned Release/notarized distribution. Use metadata only in preparation;
never read private keys, print device identifiers or enroll devices here.

When the toolchain is available, run compilation only through
`FACTORY_HEAVY_RUNNER` according to its help. Copy the Apple source into a unique
ignored directory **inside the assigned workspace**, generate the project there,
and give each unsigned build its own DerivedData. Use the documented Mac and
generic iOS destinations with `CODE_SIGNING_ALLOWED=NO` and
`REGISTER_APP_WITH_LAUNCH_SERVICES=NO` (Xcode otherwise registers a built Mac app
even without installing or launching it). Do not install/launch,
upload, register launchd, download toolchains, enable automatic provisioning, or
change entitlements. Unsigned output is not an installable signed iPhone build,
and simulator/fixture success never counts as physical evidence.

## Checklist A — operator physical iPhone acceptance (F-0074)

Use an explicitly designated isolated test workspace, not production content.
No model request is authorized by this checklist.

1. Confirm the real Bot backend and controller remain independently running.
   Record UTC time, revision, canonical instance/workspace IDs and verified origin.
   Connect the physical iPhone and Mac to the same intended tailnet; operator
   checks membership, MagicDNS, ACL access and system-trusted TLS from the phone.
   Check the actual Bot setup response, not a landing page. Do not disable TLS.
2. Use the signed installed Mac/iOS builds reviewed above. In Mac Connect iPhone,
   verify authenticated instance/workspace and exact origin. Create a fresh QR
   only after readiness succeeds. Keep QR/link/codes out of logs/screenshots.
3. On the physical phone scan or securely paste locally; review trusted origin,
   instance, workspace name/ID and expiry before **Request connection**. Compare
   exact device name and six-digit code on both devices; operator approves only
   the matching request. Verify completion, not merely approval or a pending UI.
4. Confirm the phone has its own revocable session and the same owner account,
   workspace, selected Bot, assigned execution machine and conversation ID as
   Web/Mac. Record safe IDs/build versions, not credentials.
5. Exercise harmless bidirectional message sync only in a verified **non-executing**
   conversation/path. First confirm Send cannot start a model/Bot run. If the
   available Bot chat always submits a run, stop and record this acceptance step
   blocked pending explicit execution-time model authorization; do not send a
   supposedly harmless prompt. When authorized, record both message IDs and
   appearance once on both sides, without private message text.
6. Briefly disconnect/reconnect phone networking; confirm offline retained state,
   verified reconnect and no duplicated sends/approval. Quit/relaunch the same
   installed phone app and verify the same identity/selection restores.
7. Close/quit only the desktop **UI**, not its backend/controller or host. Verify
   the independently running backend is still reachable and the phone reconnects
   to the same workspace. A sleeping/offline host is a different condition.
8. Reopen desktop; revoke exactly the test phone device/session. Confirm phone
   becomes reconnect-required and cannot access fresh authenticated data. Cached
   content is not proof of continuing authority. Re-pairing requires new consent.

## Checklist B — provider onboarding acceptance (F-0080)

Blocked on F-0076/F-0077/F-0079 until merged and available on all relevant clients.
Use the same isolated workspace and coordinate F-0069/F-0075; no new accounts,
live credential replacement or model invocation is authorized by preparation.

1. On a deliberately empty **isolated** instance, the operator explicitly performs
   the existing provider-free owner bootstrap. Verify workspace access without a
   provider or default model; a second owner claim must be refused. Never reset a
   configured instance to stage this check.
2. From the implemented Providers flow, select the intended execution target and
   Codex device-code login. The operator uses their physical phone to review the
   real provider verification origin/account and authorize the displayed code.
   Do not save login URLs, codes, cookies or tokens in evidence. Denial/expiry is
   not a successful login; do not claim success from a mocked response.
3. Verify safe status/receipt evidence that credentials were stored on the intended
   execution machine, not accidentally on the phone, UI host or another worker.
   If existing live credentials would be replaced, stop for separate approval.
4. Refresh Web, iOS and desktop and compare provider/account-status projection,
   target/workspace identity and error state consistently. “Configured” alone is
   not authenticated provider evidence. Record safe status/timestamps only.
5. Deliberately select the provider/model and Bot/machine; do not infer defaults.
   A real model request requires separate explicit authorization **at execution
   time**. Without it, record model execution as not tested, not passed.

## Evidence and one-message request

Machine-specific discovery belongs in the task handoff, not a committed verified
address. Record each check's real exit code, exact blockers, code/toolchain/
network/signing/device categories and which automated preparation completed.
Leave operator acceptance `needs_input`; never change task status in preparation.

Append the following **once**, to the existing F-0074/F-0080 threads only after
code, host origin/identity and install prerequisites are ready (otherwise report
blockers rather than asking the operator to debug unfinished preparation):

> Preparation is ready for the existing F-0074/F-0080 acceptance. Please use your
> physical iPhone and the reviewed signed builds on the same tailnet, review the
> verified origin/instance and isolated workspace shown by Connect iPhone, scan
> locally, compare the exact device/code and explicitly approve. Follow checklists
> A/B in `docs/user-guide/phone-acceptance.md`: same Bot/conversation, permitted
> bidirectional sync, reconnect/relaunch, desktop UI closed with backend up, then
> revoke the test phone. For Codex, authorize the real device login on your phone,
> confirm credentials/status on the intended execution target and all three UIs,
> and deliberately select provider/model/Bot. Do not share QR/login links, codes
> or credentials. No model request is authorized unless you explicitly approve it
> at execution time; stop if message sync would invoke one. Please return safe
> IDs, build versions, timestamps and pass/block observations only. These tasks
> remain operator-owned needs_input until actual physical/provider evidence.
