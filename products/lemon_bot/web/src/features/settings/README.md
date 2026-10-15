# Owner settings and durable inbox

`SettingsScreen({ route })` is the entry for account, your workspace, notifications,
voice, policies, usage, about, cleanup and inbox. It consumes the canonical named
owner DTOs through the typed product SDK and shared authenticated `useApp` / `useQuery`.

## State and permissions

Every state-changing request carries a fresh intent nonce and the latest loaded
revision where the canonical body requires one. Requests are never queued offline
or automatically replayed. An ambiguous transport/provider outcome blocks another
mutation until the user explicitly reconciles through authoritative reads. Query
failures remain errors rather than empty inventories. Shared `useQuery.reload()`
must reject a failed read so reconciliation cannot unlock on failure.

Workspace settings belong to the authenticated owner: name, timezone and enabled
state only. There is no membership, invitation, ownership-transfer or Team directory
UI. Required and personal action rules retain their real policy semantics.
Destructive account operations use the server's scope preview and typed-name
confirmation; exact device, session and rule revocations remain explicit real API calls.

Paired device sessions display **Until revoked** when `AuthSession.expiresAtMs` is
null; ordinary sessions show their bounded expiry. Removing a device revokes its
authority, not its local files. Phone pairing itself lives in the shell-owned
`features/pairing` screen (`device.pairing`), not a second settings auth plane.

`settings.instance` is the service/link/runtime destination shared by Settings,
connection recovery and About. Owners/admins read the canonical `GET /instance`;
members see an access explanation without issuing that request. Only owners see
runtime actions. Start is disabled while connected, and Stop/Restart require a
dialog explaining that Bots stop working. Commands run only on explicit clicks,
never from polling. Reads refresh every 10 seconds while visible (2 seconds while
a command runs), preserve stale details on read errors, and expose bounded command
output and link errors behind Details with Copy controls.


## Browser integrations

- The shell owns initial installation registration. Push settings PATCH only the
  exact `useApp().device.id` after locating its latest revision in GET /devices.
  Permission prompting, `/service-worker.js` registration, PushManager subscription
  and backend registration happen only on an explicit enable action. Browser
  permission, subscription, backend provider capability and product delivery are
  separate states. Disabling one account/device does not unsubscribe other saved
  accounts sharing the browser subscription. Explicit enable replaces stale VAPID
  key subscriptions when necessary.
- Account SSO reauthentication uses S256 PKCE and an operator-allowlisted
  same-origin `/?screen=settings.account` redirect. Callback fields are `flowId`
  and `completionCode`. Exchange requires a user click; only the temporary flow
  verifier is tab/session stored. The five-minute reauthentication token is kept
  only in component memory and consumed for confirmed account deletion.
- Microphone inspection starts only from its button, requests the selected real
  input, and stops tracks on Stop or unmount. Device selection uses the agreed
  browser-local key `lemonbot.microphoneDeviceId`, consumed by the voice overlay.
  No recording or upload happens in the input test. Local/browser speech and
  configured backend speech are distinguished; backend samples use real audio
  attachment download bytes with revocable object URLs.
- Diagnostic copies are deliberately allowlisted: versions, opaque IDs, service
  state, error codes/request IDs and measurement/generated timestamps. They omit
  exception messages, transcript, paths, credentials and push registration data.
  The API does not expose attempt counts, so diagnostics say so rather than
  inventing them. Client/device version is the shell package version `1.0.0`.

## Navigation

Inbox opens the canonical structured `NotificationTarget`, not the untrusted
`deepLink` string. It authorizes and cross-checks current conversation/entry,
approval, machine/Bot placement, or routine/run IDs before navigation. Opening,
reading and dismissing do not resolve a gate or replay work. Exact routine run
navigation uses `screen: 'routines', id: routineId, tab: 'runs', entryId: runId`.

Usage reads UTC `[from,to)` ranges up to 366 days and all five canonical grouping
choices. Null prices and incomplete provider data stay explicit. There are no
billing plans. `OwnerControlsScreen({ route })`, exported by `features/enterprise`,
retains optional advanced owner controls at `settings.identity`, `settings.network`,
`settings.setup` and `settings.usage.limit`. These use real configured providers
and host drivers; ordinary assistant use does not require enterprise setup.
Directory/governance, SCIM provisioning and shared export screens and their routes
are removed. Obsolete cross-human connector grants are not replaced with a new
own-account consent gate; actual native tool policy and capability review remain.

## Integration checks (not executed in this slice)

The integrating lead should type-check/build the combined web/SDK implementation
and exercise server revision/owner conflicts, failed-read reconciliation, unknown
mutations, preview expiry, password/SSO account deletion, persistent phone session
display and exact session/device revocation, real VAPID push delivery and denied OS
permissions, microphone selection/release, real speech playback, nullable usage
costs, optional configured host controls and exact expired/revoked inbox targets.
Provider paths require their actual configured services; no demo result path is
implemented here.
