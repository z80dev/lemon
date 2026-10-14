# Lemon Bot client/backend contract — v1

**Normative source of truth:** this document, [protocol.ts](protocol.ts), [cards.md](cards.md), and [coverage.md](coverage.md). These are an implementation contract, not a claim that endpoints have already shipped. Backend, TypeScript SDK/web, and Swift LemonBotKit must use the same paths, discriminator spelling, lifecycle and authorization. Product HTTP is independent of Lemon's control-plane `/ws` and its unrelated OpenAI `/v1`.

## 1. Transport, primitives, and envelopes

- Base URL: `https://<product-host>/v1`. WebSocket: `wss://<product-host>/v1/realtime`. Loopback development may use HTTP/WS; non-loopback requires TLS or an explicitly operator-trusted encrypted overlay. The backend proxies no operator credentials to clients.
- JSON is UTF-8, camelCase fields, snake_case discriminator values, no dates as strings. `ID` is opaque, nonempty, case-sensitive string; do not infer type or node identity from it. `TimestampMs` is Unix milliseconds, finite nonnegative integer. `Cursor` is an opaque **decimal string** representing an unsigned workspace event sequence (compare with bigint, never JavaScript number). Entry `seq` and `revision` are positive safe integers, scoped to conversation/resource.
- Success is the exact response type in the endpoint table, **not** `{data:…}`. GET/PATCH/PUT/actions return 200, created entities POST return 201, message/run/test submissions return 202, deletes return 200 JSON. Setup/login/invite acceptance/reauth, preview, generate, resolves, send/discard, key rotation, audio and end return 200. Webhook status exceptions are specified below.
- `Content-Type: application/json`; bodies max 1 MiB except multipart, file chunks and MCP. Unknown JSON properties, wrong enum values, nonfinite numbers and invalid ID references are rejected with `invalid_request`; omitted optional fields leave existing values unchanged, `null` clears **only** explicitly nullable fields. Arrays in PATCH replace completely; preferences/settings objects replace completely. Responses include all required fields and explicit nulls. No arbitrary runtime/BEAM terms or provider exceptions.
- `X-Request-Id` is generated for every response and echoed in failures; accept an incoming diagnostic ID only as non-authoritative tracing. `Cache-Control: no-store` for auth, secrets, signed URLs, private resources. CORS is same-origin unless explicitly configured trusted frontend origins; Authorization bearer, not cookies, authorizes product routes. Deny unsolicited browser origins on WebSocket/MCP. Static web assets live outside `/v1`.
- Failures always `ErrorEnvelope`: `{"error":{"code":"revision_conflict","message":"Resource changed; reload before editing.","requestId":"req_1","retrySafe":true,"details":{"currentRevision":3}}}`. Message/details are bounded and secret-scrubbed. `retrySafe` concerns whether the **same intent** can safely be attempted, not permission to generate another nonce.

| HTTP | ErrorCode | Meaning |
|---|---|---|
| 400 | invalid_request | Malformed body/query/unsupported field or invalid constraint |
| 401 | unauthenticated | Missing/expired/revoked session, invalid setup/invite/hook token |
| 403 | forbidden, policy_denied | Principal/ACL/action ceiling refuses operation |
| 404 | not_found | Missing resource or invisible private resource (do not reveal existence) |
| 409 | conflict, nonce_conflict, revision_conflict, confirmation_required, outcome_unknown | Lifecycle/nonce/revision mismatch or unresolved external effect |
| 410 | expired, cursor_expired | Gate/link/confirmation/replay window expired |
| 413 | too_large | Request/attachment exceeds bound |
| 415 | unsupported_media | Unsupported audio/avatar/file encoding |
| 429 | rate_limited | `Retry-After` seconds; no mutation dispatched |
| 503 | machine_offline, upstream_unavailable, capability_unavailable | Required node/control/provider unavailable; never report fake success/empty state |
| 500 | internal_error | Sanitized unexpected fault; retrySafe false unless proven pre-dispatch |

All table rows inherit malformed input 400, unauthenticated 401 (unless Public/Hook), ACL/not-found 403/404, throttling 429, and unexpected 500. Mutations additionally inherit `nonce_conflict`, and `revision_conflict` when their request extends `Update`; platform-backed mutations additionally inherit `outcome_unknown`. The **Errors** column adds operation-specific codes. Read failures never become an empty collection or idle status.

### Pagination and filters

Every `Page<T>` is `{items:T[],nextCursor:Cursor|null}`. `limit` default 50, 1–200. Cursor is opaque signed keyset state bound to user, endpoint, query filters and sort; changing filters invalidates it. REST list cursors are not realtime cursors despite their shared string type. Lists default descending `(createdAtMs,id)`; sections ascending `(rank,id)`, files ascending `(name,path)` directories first, templates/bots requested query ranking deterministic then ID. Entries are chronological ascending within each page: first fetch returns latest `limit`; `nextCursor` pages **older** history. `beforeSeq` and `afterSeq` are mutually exclusive with one another and with cursor; `afterSeq` pages ascending new entries. REST cursors live 24 h; changed/deleted items may vanish between pages; deduplicate IDs. Query booleans `true|false`, numbers decimal; list filters (`kinds`) comma-separated. No undocumented offset, total-count or arbitrary sort fields.

### Idempotency, revisions, and destructive intent

`Mutation.clientNonce` is required on every authenticated state-changing JSON request except password reauth. UUID v4/ULID or 16–128 URL-safe random characters; device may persist unsent text/files, but **never queue destructive operations or approvals offline**. Reserve atomically under `(workspace,user-or-bot,method,normalized-path,clientNonce)` before side effects; persist canonical request hash and exact receipt for at least 30 days. Concurrent identical calls share the reservation/receipt; different body is `nonce_conflict`. Auth/setup use server-controlled anonymous scope plus normalized email; hook key principal binds routine. Bearer tokens/secret values are never stored in a raw request hash journal (use keyed digest and encrypted one-time result where necessary). Replaying after session revocation still requires a valid principal.

A connection timeout is **not** proof of failure. An uncertain mutation retains its reserved IDs and reports `outcome_unknown` with `details:{resourceIds:[…],runId?:…}` and `retrySafe:false`, or a 202 receipt whose status is outcome_unknown. GET the named resource / GET runs with clientNonce; do not blindly submit a new mutation. Repeating the same nonce returns/reconciles the reservation, never redispatches. Reauth/password/secret input is never auto-retried. Failed pre-dispatch requests have retrySafe true and no external effects.

Every mutable `Resource` starts revision 1. `Update.revision` must match; fail 409 before effects. Returned resource and upsert event carry incremented revision. Card resolutions compare both resource/gate current revision and state. Preview returns `Confirmation` valid five minutes, single-use and bound to principal, exact ID, operation, resource revision, effect/candidate set and destination for move. Exact `confirmName` is displayed name; account delete uses email. A stale preview must be repeated. Required preview routes are listed; previews never mutate targets. Section/template/attachment/skill/secret/consent/rule deletions are narrowly scoped explicit UI confirmations rather than multi-resource cascades and use their listed request bodies.

## 2. Accounts, credentials, roles, and ACL

One product deployment has one workspace and one attached Lemon swarm. No anonymous signup. `GET /setup` exposes only setupRequired/version/apiVersion. Backend prints a cryptographically random, one-use setup code to its operator terminal on empty DB; POST /setup atomically creates owner, workspace, user and session, consumes code, and rejects repeated bootstrap with conflict. Passwords are 12–1024 UTF-8 bytes, email normalized/unique, display/workspace names 1–120 chars; Bun.password argon2id or bcrypt, never plaintext. Setup codes are not embedded in static assets or logged HTTP requests. Login is uniformly unauthenticated on wrong email/password, rate limited; invitations create new local accounts (matching invited normalized email) or attach existing local account after authenticating that account—never reset an existing password from an invite.

AuthResult.token is a cryptographically random opaque bearer; store only digest, default session lifetime 30 days, no refresh-token mechanism. Obtain a new login on expiration. Local accounts may save several backend/account pairs on a client; credential stores are Keychain on Apple, secure session storage on web (not in URLs/logs); sign-out removes that account's cache. POST /auth/logout revokes current session, DELETE /auth/sessions/:id revokes an owned session. Password change revokes other sessions, not current one. POST /auth/reauth validates current password and returns a single-use token bound to user, valid five minutes, required for account deletion.

Role labels in table:

- **Public:** setup/login/invite acceptance and public template detail only; policies still apply.
- **Member:** enabled workspace member; resource is visible to them. Personal bots/conversations/memory/routines/attachments belong only to owner. A role admin/owner is **not** permission to read another member's private transcripts/notes. Search/realtime/download inherit the same ACL. Workspace disabled blocks member actions but owners/admins can fix workspace settings.
- **Own:** Member plus ownership of user/device/session/composer/section/routine/draft/notification/connector account. Owner-only deletion of own personal objects; admin may delete Team Bot with preview but cannot inspect private content.
- **Manage bot:** Member who owns bot or is its manager; bot owner controls publishing/unpublishing and manager assignment. Owner/admin alone sets required flag. Team setup can be read by published collaborators; write by maintainers. Unpublished bots visible only to maintainers. Required published bots cannot be hidden by other members.
- **Machine:** Member listed as machine owner/accessUserIds, or workspace owner/admin with explicit host-management authority. Full terminal/file/secret access is privileged; bots alone never confer user host access. Creating/sharing nodes requires owner/admin. All bots on a shared machine can reach ambient host files/browser/CLI identities: ACLs are product access controls, **not OS isolation**.
- **Target:** Member exactly matching gate targetUserId/account owner; admins/managers cannot answer for them. Group sensitive requests are rerouted to a private task/DM and group gets a notice/link only.
- **Admin/Owner:** workspace role admin-or-owner / owner-only; managing membership cannot demote/remove the final owner. Ownership transfer is PATCH /workspace ownerUserId (enabled member), atomic promotion/demotion. Membership removal/disabling revokes sessions/devices/WS access and cancels pending gates for that principal, stops future owned routines; does not delete host files or provider logins.
- **Hook:** current routine webhook key in Authorization bearer; never a product session or operator token.

Device registration is authenticated POST /devices keyed by `(userId,installationId)`; repeated installs update the same device. deviceId is metadata, not authority. Push tokens belong to exact installation/user; logout/account removal disables delivery unless another valid session owns that same installation. Tokens are write-only; Device never returns push credentials. APNs topic/environment must match server allowlist. Web Push endpoint must be HTTPS on an allowed push-service origin, public resolved address, no redirects; reject arbitrary SSRF destinations. Optional VAPID public key appears in capabilities, private key never does.

## 3. REST endpoint catalog

The catalogs in this section and §§10–11 together are exhaustive. Substitute opaque path IDs, percent-encode them and `:name`; no slash in an ID. Bodies/responses are exported wire types from protocol.ts; `undefined` means no body/query. `Page<T>`, intersections and `Omit` define JSON exactly. Multipart exceptions §4; standard SCIM/redirect exceptions §11. Roles include all ACL rules above. Unlisted methods return 404/405; clients never call control-plane RPC paths.
| Method and path (under /v1) | Request | Response | Query | Required role / ACL | Additional errors |
|---|---|---|---|---|---|
| `GET /setup` | `undefined` | `SetupStatus` | `undefined` | Public | conflict, expired |
| `POST /setup` | `SetupRequest` | `AuthResult` | `undefined` | Public | conflict, expired |
| `POST /auth/login` | `LoginRequest` | `AuthResult` | `undefined` | Public | conflict, expired |
| `POST /auth/invites/accept` | `AcceptInviteRequest` | `AuthResult` | `undefined` | Public | conflict, expired |
| `POST /auth/reauth` | `ReauthRequest` | `ReauthResult` | `undefined` | Own | expired |
| `GET /auth/sessions` | `undefined` | `Page<AuthSession>` | `PageQuery` | Own | expired |
| `DELETE /auth/sessions/:id` | `Mutation` | `Deleted` | `undefined` | Own | expired |
| `POST /auth/logout` | `Mutation` | `Empty` | `undefined` | Own | expired |
| `GET /me` | `undefined` | `User` | `undefined` | Own | expired |
| `PATCH /me` | `UserUpdate` | `User` | `undefined` | Own | expired |
| `PUT /me/password` | `PasswordUpdate` | `Empty` | `undefined` | Own | expired |
| `POST /me/preview` | `PreviewRequest` | `Confirmation` | `undefined` | Own | expired |
| `DELETE /me` | `AccountDelete` | `Deleted` | `undefined` | Own | expired |
| `GET /workspace` | `undefined` | `Workspace` | `undefined` | Member | — |
| `PATCH /workspace` | `WorkspaceUpdate` | `Workspace` | `undefined` | Owner | — |
| `GET /members` | `undefined` | `Page<Member>` | `PageQuery` | Own | expired |
| `PATCH /members/:id` | `MemberUpdate` | `Member` | `undefined` | Own | expired |
| `POST /members/:id/preview` | `PreviewRequest` | `Confirmation` | `undefined` | Own | expired |
| `DELETE /members/:id` | `Confirm` | `Deleted` | `undefined` | Own | expired |
| `GET /invites` | `undefined` | `Page<MemberInvite>` | `PageQuery` | Admin | conflict, expired |
| `POST /invites` | `InviteCreate` | `InviteIssued` | `undefined` | Admin | conflict, expired |
| `DELETE /invites/:id` | `Mutation` | `Deleted` | `undefined` | Admin | conflict, expired |
| `GET /devices` | `undefined` | `Page<Device>` | `PageQuery` | Own | expired |
| `POST /devices` | `DeviceRegister` | `Device` | `undefined` | Own | expired |
| `PATCH /devices/:id` | `DeviceUpdate` | `Device` | `undefined` | Own | expired |
| `DELETE /devices/:id` | `Mutation` | `Deleted` | `undefined` | Own | expired |
| `GET /capabilities` | `undefined` | `Capabilities` | `undefined` | Member | — |
| `GET /sync` | `undefined` | `Snapshot` | `undefined` | Member | — |
| `GET /machines` | `undefined` | `Page<Machine>` | `PageQuery` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `POST /machines` | `MachineAttach` | `MachineAttachResult` | `undefined` | Admin | conflict, upstream_unavailable |
| `GET /machines/:id` | `undefined` | `Machine` | `undefined` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `PATCH /machines/:id` | `MachineUpdate` | `Machine` | `undefined` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `POST /machines/:id/reconnect` | `MachineReconnect` | `MachineInvite` | `undefined` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `GET /machines/:id/invites` | `undefined` | `Page<MachineInvite>` | `PageQuery` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `DELETE /machines/:id/invites/:inviteId` | `Mutation` | `Deleted` | `undefined` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `GET /machines/:id/host` | `undefined` | `HostInfo` | `undefined` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `POST /machines/:id/preview` | `PreviewRequest` | `Confirmation` | `undefined` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `DELETE /machines/:id` | `Confirm` | `Deleted` | `undefined` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `GET /machines/:id/files` | `undefined` | `Page<FileInfo>` | `FileListQuery` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `GET /machines/:id/files/stat` | `undefined` | `FileInfo` | `FilePathQuery` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `GET /machines/:id/files/read` | `undefined` | `FileChunk` | `FileReadQuery` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `PUT /machines/:id/files` | `FileWrite` | `FileInfo` | `undefined` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `POST /machines/:id/files/mkdir` | `FileMkdir` | `FileInfo` | `undefined` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `POST /machines/:id/files/move` | `FileMove` | `FileInfo` | `undefined` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `POST /machines/:id/files/preview` | `FilePreview` | `Confirmation` | `undefined` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `DELETE /machines/:id/files` | `FileDelete` | `Deleted` | `undefined` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `POST /machines/:id/files/import` | `FileImport` | `Attachment` | `undefined` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `GET /machines/:id/secrets` | `undefined` | `Page<Secret>` | `PageQuery` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `PUT /machines/:id/secrets/:name` | `SecretSet` | `Secret` | `undefined` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `DELETE /machines/:id/secrets/:name` | `Mutation` | `Deleted` | `undefined` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `POST /machines/:id/terminals` | `TerminalOpen` | `Terminal` | `undefined` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `GET /terminals/:id` | `undefined` | `Terminal` | `undefined` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `POST /terminals/:id/input` | `TerminalInput` | `Empty` | `undefined` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `POST /terminals/:id/resize` | `TerminalResize` | `Terminal` | `undefined` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `DELETE /terminals/:id` | `Mutation` | `Terminal` | `undefined` | Machine | machine_offline, upstream_unavailable, capability_unavailable, policy_denied |
| `GET /bots` | `undefined` | `Page<Bot>` | `PageQuery & { visibility?: Bot['visibility']; query?: string; machineId?: ID; published?: boolean; hidden?: boolean }` | Member | machine_offline, upstream_unavailable, policy_denied, conflict |
| `POST /bots` | `BotCreate` | `Bot` | `undefined` | Member + Machine | machine_offline, upstream_unavailable, policy_denied, conflict |
| `GET /bots/:id` | `undefined` | `Bot` | `undefined` | Member | machine_offline, upstream_unavailable, policy_denied, conflict |
| `PATCH /bots/:id` | `BotUpdate` | `Bot` | `undefined` | Manage bot | machine_offline, upstream_unavailable, policy_denied, conflict |
| `POST /bots/:id/duplicate` | `BotDuplicate` | `Bot` | `undefined` | Manage bot | machine_offline, upstream_unavailable, policy_denied, conflict |
| `POST /bots/:id/team-copy` | `BotTeamCopy` | `Bot` | `undefined` | Manage bot | machine_offline, upstream_unavailable, policy_denied, conflict |
| `POST /bots/:id/preview` | `PreviewRequest` | `Confirmation` | `undefined` | Manage bot | machine_offline, upstream_unavailable, policy_denied, conflict |
| `DELETE /bots/:id` | `Confirm` | `Deleted` | `undefined` | Manage bot | machine_offline, upstream_unavailable, policy_denied, conflict |
| `POST /bots/:id/move` | `BotMove` | `Bot` | `undefined` | Manage bot | machine_offline, upstream_unavailable, policy_denied, conflict |
| `PATCH /bots/:id/sidebar` | `SidebarUpdate` | `Bot` | `undefined` | Own sidebar | policy_denied |
| `POST /bots/:id/avatar/generate` | `AvatarGenerate` | `Attachment` | `undefined` | Manage bot | machine_offline, upstream_unavailable, policy_denied, conflict |
| `GET /sections` | `undefined` | `Page<Section>` | `PageQuery` | Own | — |
| `POST /sections` | `SectionCreate` | `Section` | `undefined` | Own | — |
| `PATCH /sections/:id` | `SectionUpdate` | `Section` | `undefined` | Own | — |
| `DELETE /sections/:id` | `Update` | `Deleted` | `undefined` | Own | — |
| `GET /templates` | `undefined` | `Page<BotTemplate>` | `PageQuery & { query?: string }` | Member | policy_denied, expired, conflict |
| `POST /templates` | `TemplateCreate` | `BotTemplate` | `undefined` | Member | policy_denied, expired, conflict |
| `GET /templates/:id` | `undefined` | `BotTemplate` | `undefined` | Member | policy_denied, expired, conflict |
| `PATCH /templates/:id` | `TemplateUpdate` | `BotTemplate` | `undefined` | Own | policy_denied, expired, conflict |
| `DELETE /templates/:id` | `Update` | `Deleted` | `undefined` | Own | policy_denied, expired, conflict |
| `POST /templates/:id/import` | `TemplateImport` | `Bot` | `undefined` | Member | policy_denied, expired, conflict |
| `GET /bots/:id/export` | `undefined` | `TemplateContent` | `undefined` | Member | machine_offline, upstream_unavailable, policy_denied, conflict |
| `POST /bots/import` | `BotCreate & { content: TemplateContent; acceptedTerms: boolean }` | `Bot` | `undefined` | Member + Machine | machine_offline, upstream_unavailable, policy_denied, conflict |
| `GET /conversations` | `undefined` | `Page<Conversation>` | `PageQuery & { botId?: ID; kind?: ConversationKind }` | Member (participant) | conflict, machine_offline, policy_denied |
| `POST /conversations` | `ConversationCreate` | `Conversation` | `undefined` | Own / group creator | conflict, machine_offline, policy_denied |
| `GET /conversations/:id` | `undefined` | `Conversation` | `undefined` | Member (participant) | conflict, machine_offline, policy_denied |
| `PATCH /conversations/:id` | `ConversationUpdate` | `Conversation` | `undefined` | Own / group creator | conflict, machine_offline, policy_denied |
| `POST /conversations/:id/preview` | `PreviewRequest` | `Confirmation` | `undefined` | Own / group creator | conflict, machine_offline, policy_denied |
| `DELETE /conversations/:id` | `Confirm` | `Deleted` | `undefined` | Own / group creator | conflict, machine_offline, policy_denied |
| `POST /conversations/:id/read` | `ReadRequest` | `Conversation` | `undefined` | Member (participant) | conflict, machine_offline, policy_denied |
| `GET /conversations/:id/composer` | `undefined` | `ComposerDraft` | `undefined` | Own | conflict, machine_offline, policy_denied |
| `PUT /conversations/:id/composer` | `ComposerDraftUpdate` | `ComposerDraft` | `undefined` | Own | conflict, machine_offline, policy_denied |
| `GET /conversations/:id/entries` | `undefined` | `Page<TranscriptEntry>` | `PageQuery & { beforeSeq?: number; afterSeq?: number }` | Member (participant) | conflict, machine_offline, policy_denied |
| `POST /conversations/:id/messages` | `MessageSend` | `MessageReceipt` | `undefined` | Member (participant) | conflict, machine_offline, policy_denied |
| `GET /entries/:id` | `undefined` | `TranscriptEntry` | `undefined` | Member (conversation participant) | conflict, upstream_unavailable |
| `POST /entries/:id/reactions` | `ReactionRequest` | `TranscriptEntry` | `undefined` | Member (conversation participant) | conflict, upstream_unavailable |
| `DELETE /entries/:id/reactions` | `ReactionRequest` | `TranscriptEntry` | `undefined` | Member (conversation participant) | conflict, upstream_unavailable |
| `POST /entries/:id/feedback` | `FeedbackCreate` | `Feedback` | `undefined` | Member (conversation participant) | conflict, upstream_unavailable |
| `GET /runs` | `undefined` | `Page<Run>` | `PageQuery & { conversationId?: ID; botId?: ID; clientNonce?: string; status?: Run['status'] }` | Member (conversation participant) | conflict, upstream_unavailable |
| `GET /runs/:id` | `undefined` | `Run` | `undefined` | Member (conversation participant) | conflict, upstream_unavailable |
| `POST /runs/:id/cancel` | `RunCancel` | `Run` | `undefined` | Member (conversation participant) | conflict, upstream_unavailable |
| `POST /attachments` | `AttachmentUpload` | `Attachment` | `undefined` | Own / authorized attachment recipient | too_large, unsupported_media, conflict, expired |
| `GET /attachments` | `undefined` | `Page<Attachment>` | `PageQuery & { conversationId?: ID; botId?: ID }` | Own / authorized attachment recipient | too_large, unsupported_media, conflict, expired |
| `GET /attachments/:id` | `undefined` | `Attachment` | `undefined` | Own / authorized attachment recipient | too_large, unsupported_media, conflict, expired |
| `GET /attachments/:id/download` | `undefined` | `Download` | `undefined` | Own / authorized attachment recipient | too_large, unsupported_media, conflict, expired |
| `DELETE /attachments/:id` | `Confirm` | `Deleted` | `undefined` | Own / authorized attachment owner | too_large, unsupported_media, conflict, expired, confirmation_required |
| `GET /approvals` | `undefined` | `Page<Approval>` | `PageQuery & { state?: ResolutionState; botId?: ID }` | Member (visible gate) | expired, conflict, policy_denied, machine_offline |
| `GET /approvals/:id` | `undefined` | `Approval` | `undefined` | Member (visible gate) | expired, conflict, policy_denied, machine_offline |
| `POST /approvals/:id/resolve` | `ApprovalResolve` | `Approval` | `undefined` | Target | expired, conflict, policy_denied, machine_offline |
| `GET /questions` | `undefined` | `Page<Question>` | `PageQuery & { state?: ResolutionState }` | Member (visible gate) | expired, conflict, policy_denied, machine_offline |
| `GET /questions/:id` | `undefined` | `Question` | `undefined` | Member (visible gate) | expired, conflict, policy_denied, machine_offline |
| `POST /questions/:id/resolve` | `QuestionResolve` | `Question` | `undefined` | Target | expired, conflict, policy_denied, machine_offline |
| `GET /human-steps/:id` | `undefined` | `HumanStep` | `undefined` | Member (visible gate) | expired, conflict, policy_denied, machine_offline |
| `POST /human-steps/:id/resolve` | `HumanStepResolve` | `HumanStep` | `undefined` | Target | expired, conflict, policy_denied, machine_offline |
| `GET /secret-requests/:id` | `undefined` | `SecretRequest` | `undefined` | Member (visible gate) | expired, conflict, policy_denied, machine_offline |
| `POST /secret-requests/:id/resolve` | `SecretRequestResolve` | `SecretRequest` | `undefined` | Target | expired, conflict, policy_denied, machine_offline |
| `GET /drafts` | `undefined` | `Page<Draft>` | `PageQuery & { conversationId?: ID; state?: Draft['state'] }` | Own | conflict, policy_denied, upstream_unavailable |
| `GET /drafts/:id` | `undefined` | `Draft` | `undefined` | Own | conflict, policy_denied, upstream_unavailable |
| `PATCH /drafts/:id` | `DraftUpdate` | `Draft` | `undefined` | Own | conflict, policy_denied, upstream_unavailable |
| `POST /drafts/:id/send` | `DraftSend` | `Draft` | `undefined` | Own | conflict, policy_denied, upstream_unavailable |
| `POST /drafts/:id/discard` | `Update` | `Draft` | `undefined` | Own | conflict, policy_denied, upstream_unavailable |
| `GET /skills` | `undefined` | `Page<Skill>` | `PageQuery & { botId?: ID; query?: string }` | Member | machine_offline, conflict, policy_denied |
| `POST /skills` | `SkillCreate` | `Skill` | `undefined` | Own / Manage bot (team skill) | machine_offline, conflict, policy_denied |
| `GET /skills/:id` | `undefined` | `Skill` | `undefined` | Member | machine_offline, conflict, policy_denied |
| `PATCH /skills/:id` | `SkillUpdate` | `Skill` | `undefined` | Own / Manage bot (team skill) | machine_offline, conflict, policy_denied |
| `DELETE /skills/:id` | `Update` | `Deleted` | `undefined` | Own / Manage bot (team skill) | machine_offline, conflict, policy_denied |
| `GET /routines` | `undefined` | `Page<Routine>` | `PageQuery & { botId?: ID; enabled?: boolean }` | Own | conflict, machine_offline, upstream_unavailable, expired |
| `POST /routines` | `RoutineCreate` | `Routine` | `undefined` | Own | conflict, machine_offline, upstream_unavailable, expired |
| `GET /routines/:id` | `undefined` | `Routine` | `undefined` | Own | conflict, machine_offline, upstream_unavailable, expired |
| `PATCH /routines/:id` | `RoutineUpdate` | `Routine` | `undefined` | Own | conflict, machine_offline, upstream_unavailable, expired |
| `POST /routines/:id/preview` | `PreviewRequest` | `Confirmation` | `undefined` | Own | conflict, machine_offline, upstream_unavailable, expired |
| `DELETE /routines/:id` | `Confirm` | `Deleted` | `undefined` | Own | conflict, machine_offline, upstream_unavailable, expired |
| `POST /routines/:id/test` | `Mutation` | `RoutineRun` | `undefined` | Own | conflict, machine_offline, upstream_unavailable, expired |
| `GET /routines/:id/runs` | `undefined` | `Page<RoutineRun>` | `PageQuery` | Own | conflict, machine_offline, upstream_unavailable, expired |
| `GET /routine-runs/:id` | `undefined` | `RoutineRun` | `undefined` | Own | conflict, machine_offline, upstream_unavailable, expired |
| `POST /routine-runs/:id/cancel` | `Mutation` | `RoutineRun` | `undefined` | Own | conflict, machine_offline, upstream_unavailable, expired |
| `POST /routines/:id/webhook-key` | `Mutation` | `WebhookKey` | `undefined` | Own | conflict, machine_offline, upstream_unavailable, expired |
| `DELETE /routines/:id/webhook-key` | `Mutation` | `Empty` | `undefined` | Own | conflict, machine_offline, upstream_unavailable, expired |
| `POST /hooks/:routineId` | `HookRequest` | `HookReceipt` | `undefined` | Hook | expired, conflict, policy_denied, machine_offline, upstream_unavailable |
| `GET /bots/:id/memory` | `undefined` | `Page<Memory>` | `PageQuery & { query?: string; scope?: Memory['scope'] }` | Member (scoped memory) | machine_offline, upstream_unavailable, policy_denied, conflict |
| `POST /bots/:id/memory` | `MemoryCreate` | `Memory` | `undefined` | Own / Manage bot (team memory) | machine_offline, upstream_unavailable, policy_denied, conflict |
| `GET /bots/:id/memory/export` | `undefined` | `MemoryExport` | `undefined` | Member (scoped memory) | machine_offline, upstream_unavailable, policy_denied, conflict |
| `POST /bots/:id/memory/import` | `MemoryImport` | `MemoryImportResult` | `undefined` | Own / Manage bot (team memory) | machine_offline, upstream_unavailable, policy_denied, conflict, expired, confirmation_required |
| `GET /memory/:id` | `undefined` | `Memory` | `undefined` | Own scope / published team-memory reader | machine_offline, upstream_unavailable |
| `PATCH /memory/:id` | `MemoryUpdate` | `Memory` | `undefined` | Own scope / Manage bot (team memory) | machine_offline, upstream_unavailable, outcome_unknown |
| `DELETE /memory/:id` | `Confirm` | `Deleted` | `undefined` | Own / Manage bot (team memory) | expired, confirmation_required, machine_offline |
| `GET /search` | `undefined` | `Page<SearchHit>` | `SearchQuery` | Member | — |
| `GET /notifications` | `undefined` | `Page<Notification>` | `PageQuery & { unread?: boolean }` | Own | — |
| `PATCH /notifications/:id` | `NotificationUpdate` | `Notification` | `undefined` | Own | — |
| `POST /notifications/read-all` | `NotificationReadAll` | `Empty` | `undefined` | Own | — |
| `GET /usage` | `undefined` | `UsageReport` | `UsageQuery` | Member (own); Admin (workspace) | upstream_unavailable |
| `GET /audit` | `undefined` | `Page<AuditRecord>` | `PageQuery & { actorId?: ID; resourceId?: ID; fromAtMs?: TimestampMs; toAtMs?: TimestampMs }` | Admin | — |
| `GET /policies` | `undefined` | `Policies` | `undefined` | Member | policy_denied, conflict |
| `PATCH /policies` | `PoliciesUpdate` | `Policies` | `undefined` | Admin | policy_denied, conflict |
| `POST /policies/rules` | `PolicyRuleCreate` | `PolicyRule` | `undefined` | Own (personal rules) / Admin (required rules) | policy_denied, conflict |
| `PATCH /policies/rules/:id` | `PolicyRuleUpdate` | `PolicyRule` | `undefined` | Own (personal rules) / Admin (required rules) | policy_denied, conflict |
| `DELETE /policies/rules/:id` | `Update` | `Deleted` | `undefined` | Own (personal rules) / Admin (required rules) | policy_denied, conflict |
| `GET /bots/:id/connectors` | `undefined` | `Page<Connector>` | `PageQuery` | Member | machine_offline, upstream_unavailable, policy_denied, conflict |
| `POST /bots/:id/connectors` | `ConnectorCreate` | `Connector` | `undefined` | Manage bot / Own account | machine_offline, upstream_unavailable, policy_denied, conflict |
| `PATCH /connectors/:id` | `ConnectorUpdate` | `Connector` | `undefined` | Own account / Manage bot (shared) | expired, policy_denied, upstream_unavailable |
| `DELETE /connectors/:id` | `Confirm` | `Deleted` | `undefined` | Own account / Manage bot (shared) | expired, policy_denied, upstream_unavailable, confirmation_required |
| `POST /connectors/:id/auth` | `Mutation` | `ConnectorAuth` | `undefined` | Own account / Manage bot (shared) | expired, policy_denied, upstream_unavailable |
| `GET /connector-auth/:id` | `undefined` | `ConnectorAuth` | `undefined` | Own account / Manage bot (shared) | expired, policy_denied, upstream_unavailable |
| `GET /consents` | `undefined` | `Page<ConnectorConsent>` | `PageQuery` | Own account | expired, conflict |
| `POST /consents/:id/resolve` | `ConsentResolve` | `ConnectorConsent` | `undefined` | Own account | expired, conflict |
| `DELETE /consents/:id` | `Update` | `Deleted` | `undefined` | Own account | expired, conflict |
| `GET /channels` | `undefined` | `Page<ChannelBinding>` | `PageQuery & { botId?: ID }` | Member | policy_denied, capability_unavailable, upstream_unavailable |
| `POST /channels` | `ChannelCreate` | `ChannelBinding` | `undefined` | Manage bot | policy_denied, capability_unavailable, upstream_unavailable |
| `PATCH /channels/:id` | `ChannelUpdate` | `ChannelBinding` | `undefined` | Manage bot | policy_denied, capability_unavailable, upstream_unavailable |
| `DELETE /channels/:id` | `Update` | `Deleted` | `undefined` | Manage bot | policy_denied, capability_unavailable, upstream_unavailable |
| `GET /event-sources` | `undefined` | `ExternalSource[]` | `undefined` | Member | — |
| `POST /voice/sessions` | `VoiceStart` | `VoiceSession` | `undefined` | Own + conversation participant | conflict, unsupported_media, too_large, capability_unavailable, upstream_unavailable |
| `GET /voice/sessions/:id` | `undefined` | `VoiceSession` | `undefined` | Own + conversation participant | conflict, unsupported_media, too_large, capability_unavailable, upstream_unavailable |
| `PATCH /voice/sessions/:id` | `VoiceUpdate` | `VoiceSession` | `undefined` | Own + conversation participant | conflict, unsupported_media, too_large, capability_unavailable, upstream_unavailable |
| `POST /voice/sessions/:id/end` | `Mutation` | `VoiceSession` | `undefined` | Own + conversation participant | conflict, unsupported_media, too_large, capability_unavailable, upstream_unavailable |
| `POST /audio/transcriptions` | `TranscriptionRequest` | `Transcription` | `undefined` | Own + conversation participant | conflict, unsupported_media, too_large, capability_unavailable, upstream_unavailable |
| `POST /audio/speech` | `SpeechRequest` | `SpeechResult` | `undefined` | Own + conversation participant | conflict, unsupported_media, too_large, capability_unavailable, upstream_unavailable |
| `GET /downloads/:ticket` | `undefined` | `BinaryBody` | `undefined` | Signed capability | expired, not_found, forbidden |
| `GET /connectors/oauth/callback` | `undefined` | `ConnectorAuth` | `OAuthCallbackQuery` | OAuth state | expired, conflict, upstream_unavailable |

### Resource behavior and validation (applies to all catalog operations)

**Accounts/workspace.** GET /me returns caller only; members exposes identity/roles, not private content. Invite tokens/URLs only at issuance, roles never owner, default seven-day/max 30-day expiry. DELETE /me needs one-use password or OIDC reauth, preview and typed email; final owner must transfer first, Team bots transfer or explicitly preview removal. Remove product-owned personal bots/routines/conversations/notes/devices/attachments and revoke sessions immediately. Node files/browser sessions/provider OAuth and external billing are independently revoked by user/operator; backups follow disclosed deployment retention, not invented SLA. Local auth remains available for bootstrap and configured break-glass owner; configured OIDC/SCIM and directory access are real alternatives (§11), not permission to silently weaken required SSO.

**Machines.** POST /machines is attach: name 1–120, nodeName `[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}`, unique durable swarm name, labels string map bounded 32 keys/256 chars each; backend calls node.pair.invite purpose lemon_bot and stores machineId→nodeId once enrolled. Default invite 15 min, maximum 24 h; joinCommand is copied exactly from platform and contains one-use invite authority, **never** operator token. MachineAttachResult contains pending machine and invite; poll machine or receive machine.upserted until online. Invites are visible only to machine owner/admin; machine access users cannot create/revoke/reconnect invites or change accessUserIds. Reconnect issues a new repair-bound invite for the **same** node identity, not a new machine; revoke old pending invites. LastSeen is durable and offline ≠ deleted. HostInfo is live, unavailable if offline, never fabricate last-known measurements as current. Detach previews affected bots/routines, cancels runs and future triggers, revokes node, removes machine from ordinary list but retains revoked tombstone for referenced bots (GET still returns revoked); bots remain visible offline until moved/deleted. No SSH removal, host uninstall/reboot/image rebuild or machine-file deletion implied. Machine manager explicitly accepts privileged host relationship. Workspace admin cannot quietly attach an arbitrary node from nodes.list: enrollment requires actual host invitation.

**Files/secrets/terminal.** Paths are destination-local under worker allowed roots, default node user's home. Reject traversal/symlink escape after canonicalization, never resolve host paths on controller/backend. File read/write chunk decoded max 1 MiB, offset nonnegative, length default/max 1 MiB, exact base64; write requires expectedModifiedAtMs for existing-file overwrite. `truncate` only with offset 0; `mkdirs` default false. File move never overwrites an existing destination; delete preview binds path/stat revision/children; exact basename confirmation; file Deleted.id is original path. ShowHidden default false; cursor bound to directory snapshot; directory mutation invalidates cursor. GET stat is not a transfer. File import reads bounded regular file into attachment storage; MIME detected server-side, ACL bound before transfer. `SecretSet` replaces value atomically, names `[A-Z][A-Z0-9_]{0,63}`, max value 32 KiB, no empty value; name/description/scope only returned. Bot-scoped names are still on the bot machine and **not an OS isolation guarantee**. Write-only prevents value entering product transcript/model/WS/push/audit; user-run shell is full host access, destination tools must scrub secret output but privileged host users can still inspect their own storage. No promise of browser secret auto-fill. A failure to list secret store is 503, not empty.

TerminalOpen requires caller-owned registered device; cols 20–500, rows 5–300. Open invokes node.shell.open with cwd interpreted on node, returns product terminal ID. Bind upstream shell to backend connection, product terminal to user+device+WS; only opener can input/resize/read/close, even admins cannot attach to another person's shell. Input decoded ≤64 KiB. WS terminal_subscribe may reattach same device's terminal with 60-second disconnect grace; backend keeps last 1 MiB or 10,000 output chunks per terminal and reports terminal_gap beyond that bound. Number seq from 1 per terminal; terminal output is not workspace replay. Close after grace, revocation, process exit, or explicit delete; shell exit ≠ bot stop. No shell output in generic audit/push.

**Bots.** Name 1–120, title max 140, job/instructions max 32 KiB each; duplicate display names allowed, IDs stable. BotCreate defaults title/job/instructions empty, character avatar (`shape:"round",color:"yellow",attachmentId:null`), voice `{voiceId:"default",speed:1,language:null}`, language null, visibility personal, skillIds empty. Create profile `lb-<stable-id-slug>` placed at enrolled online machine, generated systemPrompt includes job/instructions/base product tools. A personal bot uses canonical main session; Team Bot uses per-member private DM and bot-assigned shared machine for groups/channels. **Lemon decision:** all conversations execute on assigned machine, not invisible requester-machine switching. Team publish requires dedicated intended shared machine consent; no owner's private credentials automatically lent. Shared host credentials are explicitly available to every bot on it; stricter user privacy requires separate machine/bot, otherwise fail policy_denied. Bot managers cannot modify owner-only publish/managers fields. Avatar image is ready image AttachmentUpload(purpose avatar) then PATCH avatar; generate calls real configured image provider and returns an unattached attachment for crop/Set avatar. No provider means capability_unavailable; character option remains usable.

Duplicate carries selected profile/settings/skills, copies selected routines as **paused**, no memory/chat/attachments/secrets/logins/connector tokens. Team-copy is a distinct unpublished bot, explicit selected owned memories/skills/reference files/routines/connectors; copy only declarative connector config, never credentials/private chats. Personal Bot stays unchanged. GET export and template content omit learned memories, history, credentials, private URLs in credential fields; user review required for publication (instructions can still contain confidential prose, no magical scrub guarantee). Templates copied as separate bots, routines paused; terms accepted if third-party. Public template detail is anonymously readable only when audience public and policies.publicTemplates true; catalog listing/import authenticated. Revoking public policy blocks existing links immediately; no compatibility copy. Delete bot preview includes sessions/cards/routines/channel-binding cleanup, warns files/logins remain. Group membership updates remove deleted bot and notify room.

Move requires source bot idle (no active/unknown runs), online destination and preview bound to both placement/revision and memory+skill copy effects. Provision persona/selected enabled skills and scoped Lemon memory at destination through owning RPCs, acknowledge before switching profile node. Product transcript/IDs remain, but new destination session receives authorized product history summary; do not reuse foreign native resume. No files, browser cookies, external credentials, reference secret values or terminal sessions transferred. Notify machine_moved event; pause routine scheduling during placement change, resume prior enabled state only after provisioning acknowledged. Partial/uncertain provisioning keeps old placement (or outcome_unknown with receipts), never duplicate mutations blindly. User copies host files explicitly through authorized download/upload if desired.

**Sidebar/sections.** Bot.sidebar is a viewer projection, stored per user, not shared bot config. SidebarUpdate revision is the Bot viewer projection revision; server serializes with Bot revision for conflict detection. Hide suppresses push/sound for this viewer only, never pauses bot/routines; required Team Bots cannot be hidden except by owner. Section deletion moves all caller's bots to sectionId null. Pins, rank and sections sync all three clients; collapse layout is saved section state. Manual unread independent of pending gates. Opening chat sends read through last rendered seq; events above that remain unread. Client must not equate read with resolved.

**Conversations/messages.** dm/team_dm botIds length one, task one bot + parent required, group 2–6 distinct authorized bots and creator + invited enabled humans; channel created only by authorized channel ingress (client create kind channel fails forbidden). Personal DM only bot owner; Team DM only caller and bot, maintainers cannot read another person's DM. Repeated DM creation for same bot+user returns existing row, no duplicate canonical session. Group creator controls name/member list/lead; bot-specific sessions route with same profile placement. Added members see group's retained history: explicit UI warning. One lead defaults first bot; no mentions/reply routes lead; explicit mentions wake those bots once, everyone wakes all once, reply targets original bot if still member. Duplicate mention IDs collapse. Bot room posts do not implicitly wake peers; explicit mentions may, within verified inherited principal ACL. Normal user group attachments shared with group. Sensitive approval/secret/draft/human/login/consent gates are private to designated user and bot: create private task or team_dm and append only a group notice/link, never sensitive payload to room.

Message text max 64 KiB, can be empty **only with** ready attachment(s), ≤6 files; ready owned staging or already authorized room file references only. `/` and `@` picker selections populate references/mentions, not implicit authority; text alone does not grant connector consent. MessageReceipt includes authored message and attachment entries sharing clientNonce/batchId, and one run per target. Default mode followup; steer updates active work through placement-aware runtime; interrupt prepends and requests active cancellation. Stop uses runs/:id/cancel, not a fake "Stop now" success message. Cancel acknowledgement returns current Run (possibly still running); only terminal cancelled is proof. Completed external effects never rolled back. Receipt accepted ≠ executed/result. entry.delta appends at UTF-16 code-unit offset (Swift mirrors by UTF-16), final entry.upserted authoritative full text recovered from durable history, never the truncated Lemon completed preview. Tool_call is activity/detail, not unredacted bubble dump. Feedback/reactions never resolve approvals. Composer draft is user+conversation private, PUT compare revision, default GET returns empty draft revision 1 on creation; avoid overwriting newer server text when switching devices. iOS share extension stages attachments/text into composer and sends only explicit user action.

**Gates/drafts.** See cards.md; first authorized resolution wins atomically; stale second action conflict, same nonce exact replay. Gate timeout default/max 600000 ms, including unattended approval. Pending gates persisted with deadlines, restart rehydrates waiters or yields cancelled, never implicit approval. Questions validate required fields/options/numeric bounds, max 32 fields, unique IDs, select options 1–100; decline requires no answers, answer may not include unknown fields. Only non-secret questions; sensitive credentials use request_secret or human_step. User safe answers appear in question/card and bot tool result. Approval category visible, product approval supplements execution policy not bypass. Draft edit explicit; send freezes approved exact revision/content, enqueues bot follow-up with signed authorization reference. Agent must report verified provider send to finalize sent; mere follow-up acceptance leaves sending. If no provider confirmation, outcome_unknown; UI does not retry Send automatically. Explicit user Send is mandatory for **all** email/slack/message drafts even allow policy/routine; discard prevents any send and returns discarded. Draft send/edit/discard unavailable in groups; private task redirect instead. Send attachments/recipient limits enforce the actual provider plus email ≤10 attachments/10 MiB each/25 MiB total/50 total recipients; executable attachments rejected. Never invent provider mailbox ownership/claim or unsubscribes that configured channel cannot provide.

**Skills/routines.** Personal skills owned library, explicitly provisioned machineIds, file name from validated skill ID under destination managed skill directory; markdown max 256 KiB, name 1–120, description nonempty ≤4 KiB. Team skills manager-only; third-party instructions treated untrusted, no automatic execution on install. Disabled skill no longer injected. Write and deletion acknowledge host file RPC; do not return saved if node offline. Routines owned by creating principal even on team bot; creator-only history/edit/report. Max 50 per bot, schedule standard 5-field cron, valid IANA timezone, no executions closer than five minutes. Delegate scheduled work to Lemon cron with profileId, no second scheduler. First run next future match, no creation run. DST behavior follows canonical Lemon cron timezone scheduling and nextRunAtMs; client displays returned instant rather than independently scheduling. Pausing blocks future triggers, not active run; cancel run separately. Retain at least 20 latest RoutineRun records, no automatic mutation retry/overlap guarantee beyond canonical scheduler. Test is **real work**, 202 RoutineRun and bot chat; not dry-run. Webhook keys only for webhook trigger, returned only on create/rotate (not Routine listings), rotate revokes previous key immediately; delete disables ingress. External event trigger sources only entries advertised by GET event-sources; eventNames must be exact supported values. Operator-configured verified ingestion bridges deliver normalized new events, no backfill. Slack mention/phrase/reaction/email event filters match configured adapter capability, not an invented full GitHub/Linear/Sentry/PagerDuty event list. Long-absence pause is **explicit owner decision**, not undisclosed automatic disabling.

**Memory/search/usage/audit/policy.** Runtime personal/team memory uses assigned profile memory.*; private Team notes are backend bot+user-only SQLite, injected only to that principal. Explicit team facts require maintainers. PATCH uses owning remove/add with stable ID/revision fencing; split remote outcome may be unknown. Guided import (§10) previews exact candidate facts/provenance/exclusions into selected bot/machine/scope before confirmed memory.add; no direct unreviewed full-history import. Export only caller-visible scope. Search q 1–512, ACL before snippet/ranking, current-chat filter, unavailable index 503 not empty. Usage [from,to) ≤366 days, groupBy bot default, unknown price nullable/incomplete true, own attributed runs or admin aggregate without private transcript. Self-hosted configured spend ceilings (§11), no selling Lemon plans/entitlements/refunds. Separate sanitized audit/action/usage and explicit opt-in authorized content exports (§11), default metadata retention 90 days, no future-stream backfill. Required ask_first dominates other action rules; real auto_review or fail-closed ask_first. Product rules enforce canonical sessions.patch toolPolicy and independent explicit Send/consent. Group/network/sudo/egress/setup policy application (§11) reports actual applied host revision or fails closed, never assumes UI setting is OS enforcement.

**Connectors/channels.** HTTPS streamable MCP URL, actual account owner, explicit server origin policy, private targets only operator-approved. ConnectorCreate/Update accept **secretBindings** header→node secret name, never plaintext header credentials; machine setup (§10) and destination `${LEMON_SECRET:NAME}` resolution retain credential custody on host. OAuth account-scoped; shared only deliberate service account. auth returns state-bound 10-minute ConnectorAuth, callback verifies state/code/verifier/account, actual discovery required for connected (Added ≠ authenticated). Tools enabled list replaces complete controls; personal account Team access always explicit ConnectorConsent, exact bot/account/user and optional expiry, revocable. Channels are separate from posting MCP/event routines: configured Lemon adapter or real provider setup flow (§11), including per-bot Slack app where operator registered its OAuth/signing/install provider. Mapped user/thread and published bot enforced; no unlinked-owner authority fallback. Configured email provisioning/IMAP/SMTP and X OAuth/verified mentions have real endpoints (§11); absence is capability_unavailable with provider prerequisite, never a fake mailbox/public handle. Source-service permissions remain authoritative.

## 4. Attachment upload, URLs, and voice

POST /attachments is multipart/form-data with exactly `metadata` JSON part (`AttachmentUpload`) and one `file` binary part with filename. Reject empty, unsupported source or failed full upload; validate by sniffing content, filename sanitized, sha256 server-computed. Non-video max 25 MiB, video max 200 MiB, avatar image <25 MiB (PNG/JPEG/WebP), all clients ≤6 message files. No attachment storage paths or arbitrary privileged fetch URL accepted. Upload completion returns ready Attachment, never an upload-only unfinished placeholder. Scope at upload: conversationId or botId authorized; unscoped own staging (24 h GC unless referenced). Avatar/reference association is explicit bot update; files remain immutable, revision by creating a new attachment and new entry, not overwrite blob in place. Composer retries same nonce with identical bytes (keyed digest); no duplicate upload. No chunked multipart/resumable upload in v1; remote node file transfer uses bounded FileWrite chunks. Product stores uploaded attachments, copies authorized inputs to destination-local run directory before submitting chat (≤five bounded model images inline per runtime limits; other files passed as destination files, not misrepresented inline image messages).

GET /attachments/:id/download authorizes caller and returns Download: `{"url":"https://bot.example/v1/downloads/opaque-ticket","expiresAtMs":1791940000000,"filename":"report.pdf","mime":"application/pdf","size":4812}`. Ticket is short-lived (five minutes), attachment- and ACL-revision-bound unguessable capability; GET /downloads/:ticket accepts ticket without bearer for native players/browser downloads and rechecks revocation/resource deletion. Do not log ticket path; Referrer-Policy no-referrer. BinaryBody response original bytes, Content-Type detected MIME, Content-Disposition attachment with sanitized UTF-8 filename, Content-Length, ETag sha256, Accept-Ranges bytes; single Range supported 206 and 416 invalid range. No arbitrary redirect or open external URL proxy. Download URL never persisted as durable attachment ID. Untrusted HTML/MCP app snapshots preview in isolated sandbox without same-origin privilege, scripts/network blocked by default; fallback download always available. File viewers distinguish missing, loading, too large, render/decoding failure, unavailable and unsupported; clients support image/video/audio/PDF/text/Markdown/JSON/table/docx and isolated HTML where native renderer available, otherwise truthful downloadable original (slides may be download-only).

VoiceSettings.speed 0.5–2, language IANA-style BCP-47 or null auto-detect, voiceId provider-supported or default. Dictation preferably on-device Apple Speech/Web Speech; review/edit before ordinary MessageSend. Fallback upload audio(purpose audio) then POST /audio/transcriptions with attachmentId, optional language; returns Transcription, **never automatically sends**. Audio max 25 MiB, actual configured WAV/MP3/MP4/WebM/Opus provider formats only, duration ≤10 min; provider unavailable 503. POST /audio/speech uses real configured TTS (text ≤4096 chars per segment), returns SpeechResult persisted authorized audio and short-lived download. No silence/hash preview treated as speech. Capability flags advertise backend providers; on-device speech is a separate client capability and does not flip backend tts/stt true.

Live voice is a client STT → normal message/run stream → sentence/segment TTS loop, not raw microphone transport or existing Lemon legacy phone direct-LLM pipeline. VoiceStart allowed only in own dm/task/owned Team dm, not group/channel/teammate Team Bot. Exactly one active VoiceSession per user across devices; second 409 conflict with existing ID, user ends it explicitly first. Captured final utterances sent via MessageSend.voiceSessionId with unique nonce; streamed reply TTS associated with same session, voice transcript uses ordinary entries. No binary voice WebSocket/audio-chunk frames; mute/settings/end uses REST or WS voice frame. On-device TTS fallback allowed when backend unavailable; send_voice_memo requires real backend audio to persist. End idempotent sets duration/endedAtMs, appends one voice_call entry; existing chat work continues, late results go to main conversation. Device disconnect >60 s marks voice failed and persists summary; client restart not automatic call retry. Voice feedback only own session; lock-screen/background mic not promised. macOS/iOS microphone denial opens OS settings; web explains browser permissions.

## 5. Routine webhook ingress

Canonical URL is **POST `/hooks/:routineId` outside `/v1`** (RestEndpoints key `POST /hooks/:routineId` is the sole prefix exception). It intentionally matches architecture. Authorization: Bearer **current routine key**, JSON HookRequest `{clientNonce,payload?}`, payload optional arbitrary bounded JSON (whole request ≤1 MiB), not an arbitrary executable prompt/target. No key in query/body. Response 200 HookReceipt when accepted/started, e.g. `{ "routineRun": <RoutineRun>, "accepted": true, "status": "accepted" }`; this means submission, not completion. Uncertain submission returns 202 with accepted false/status outcome_unknown and same reserved RoutineRun, never claims other non-200 proves no work. Invalid key 401, missing routine 404 (after authentication), expired key 410, paused/disabled routine 409 conflict, wrong trigger 400, unavailable before dispatch 503. Atomic routine-key-scoped nonce prevents duplicate deliveries; no implicit automatic retries or callback URL fetching. Configured external-source bridge verifies vendor signature/delivery ID **before** calling this protected ingress or internal same owning routine submission; payload remains untrusted. RoutineRun ID can be queried by owner; webhook key cannot read workspace data. The displayed WebhookKey.header is `Authorization: Bearer <key>` and key shown only issuance/rotation; copy controls explicit.

## 6. Realtime WebSocket

Connect `/v1/realtime` without bearer query. First UTF-8 JSON frame within five seconds: `{"type":"auth","token":"product-session-token","deviceId":"device_1"}`. The token must be live; optional device is owned. Server sends ready: `{"type":"ready","userId":"user_1","workspaceId":"workspace_1","cursor":"42","earliestCursor":"1","heartbeatMs":25000}`. No other commands before auth; invalid auth closes 4401, forbidden 4403, oversized/invalid schema 4400/1009, too slow 4408. Session/member revocation closes live sockets. Max frame 1 MiB, no binary/audio frames. Ping every 25 s, close after 60 s without pong/request activity; browser client sends protocol ping and server pong.

Then `{"type":"subscribe","requestId":"sub_1","cursor":"40","conversationIds":[]}`; empty/omitted IDs = all authorized conversations. ≤200 explicit IDs, reject whole request if any inaccessible. Cursor must be decimal of this workspace and between earliest retained predecessor and ready watermark. Server snapshots high watermark, sends subscribed with effective selection and cursor=requested start, replays **authorized** persisted events with seq > cursor through watermark, sends caught_up with that watermark, then live events ordered. With no cursor subscribe starts at current watermark without replay; first client calls GET /sync to fetch bounded Snapshot at an atomic cursor then subscribes from that cursor (page hasMore collections separately). Do not use ready cursor as a snapshot of unseen data. Changing subscriptions requires cursor from the client's **prior safe snapshot** if adding conversations, otherwise refetch missing history; last ack is not proof skipped conversations loaded.

Persist one monotonically increasing workspace sequence and state change atomically in SQLite before publishing. Sequence gaps are expected due to ACL/subscription filtering. Periodic watermark lets clients advance across invisible gaps without leaking content/count detail. Persist events ≥7 days; cursor older than earliest predecessor yields error cursor_expired and no partial replay; client clears derived live state, GET /sync + list/history refetch, subscribe new cursor. No blanket controller event forwarding: resolve run/profile/session ownership, filter each resource plus current principal; private sidebar/read/composer/notification/notes projected only for owner. Deletions use persisted ACL tombstones. Membership/publish revoke prevents subsequent replay of now-inaccessible history. Bot upsert sidebar/mainConversationId viewer-projected; event global seq fixed, payload may differ safely per authorized viewer. `GET /sync` atomically snapshots product SQLite state (up to 200 per collection), includes hasMore flags; capabilities live control availability. If swarm offline retain stored resources with truthful offline/unknown state, no fake successful reconciliation. Clients page remaining collections then fetch active selected transcript; no global full-transcript snapshot implied.

RealtimeEvent exact envelope: `{"type":"event","seq":"43","event":"entry.delta","payload":{"conversationId":"c_1","entryId":"e_1","runId":"r_1","offset":0,"text":"Hello"},"timestampMs":1791940000000}`. Clients deduplicate by seq and upsert by ID+revision; assistant streaming deltas ordered/offset-checked, missing offsets require GET entry rather than concatenating blindly. Only final entry.upserted closes streaming. All durable event names/payloads below; no arbitrary string event or catch-all payload. Resource upserts include full authorized resource, not JSON Patch. IDs deleting an object refer to that exact object; seq never reused. Notifications are durable; push delivery best-effort APNs/Web Push with authenticated fetch reconciliation, no "exactly once push" claim.

| Durable event | Payload type |
|---|---|
| `user.updated` | `User` |
| `workspace.updated` | `Workspace` |
| `member.upserted` | `Member` |
| `member.deleted` | `Deleted` |
| `invite.upserted` | `MemberInvite` |
| `device.upserted` | `Device` |
| `device.deleted` | `Deleted` |
| `machine.upserted` | `Machine` |
| `machine.deleted` | `Deleted` |
| `machine_invite.upserted` | `MachineInvite` |
| `bot.upserted` | `Bot` |
| `bot.deleted` | `Deleted` |
| `section.upserted` | `Section` |
| `section.deleted` | `Deleted` |
| `template.upserted` | `BotTemplate` |
| `template.deleted` | `Deleted` |
| `conversation.upserted` | `Conversation` |
| `conversation.deleted` | `Deleted` |
| `conversation.read` | `{ conversationId: ID; userId: ID; throughSeq: number; unread: boolean }` |
| `composer.updated` | `ComposerDraft` |
| `entry.upserted` | `TranscriptEntry` |
| `entry.deleted` | `{ id: ID; conversationId: ID }` |
| `entry.delta` | `{ conversationId: ID; entryId: ID; runId: ID; offset: number; text: string }` |
| `run.upserted` | `Run` |
| `attachment.upserted` | `Attachment` |
| `attachment.deleted` | `Deleted` |
| `approval.upserted` | `Approval` |
| `question.upserted` | `Question` |
| `human_step.upserted` | `HumanStep` |
| `secret_request.upserted` | `SecretRequest` |
| `draft.upserted` | `Draft` |
| `skill.upserted` | `Skill` |
| `skill.deleted` | `Deleted` |
| `routine.upserted` | `Routine` |
| `routine.deleted` | `Deleted` |
| `routine_run.upserted` | `RoutineRun` |
| `memory.upserted` | `Memory` |
| `memory.deleted` | `{ id: ID; botId: ID; scope: Memory['scope']; userId: ID \| null }` |
| `notification.upserted` | `Notification` |
| `notification.deleted` | `Deleted` |
| `policies.updated` | `Policies` |
| `connector.upserted` | `Connector` |
| `connector.deleted` | `Deleted` |
| `connector_auth.upserted` | `ConnectorAuth` |
| `consent.upserted` | `ConnectorConsent` |
| `channel.upserted` | `ChannelBinding` |
| `channel.deleted` | `Deleted` |
| `voice.upserted` | `VoiceSession` |

### Client frames (RealtimeClientFrame)

| Frame | Exact fields beyond type | Semantics |
|---|---|---|
| auth | token, deviceId? | First only; token never appears in subsequent event/log |
| subscribe | requestId, cursor?, conversationIds? | Replace current selection, replay-before-live boundary as above |
| ack | cursor | Highest fully processed event/watermark; cannot exceed delivered cursor; optimization only, not read-state |
| ping | requestId | Server pong same requestId, heartbeat/liveness |
| typing | conversationId, active | Authorized selected room only, max once/s; expires after 5 s, not persisted |
| presence | foreground, conversationId (nullable) | Owned device session; 60-second TTL, guides push suppression, no global presence disclosure |
| terminal_subscribe | terminalId, afterSeq? | Only opening user/device; replay buffer or terminal_gap, no workspace event seq |
| voice | voiceSessionId, action mute/unmute/end | Own active session; durable voice.upserted state, idempotent action; no raw mic bytes |

Ephemeral server frames: ready/subscribed/caught_up/watermark/pong/error as protocol.ts; typing `{conversationId,userId,active,expiresAtMs}`; terminal_output `{terminalId,seq,dataBase64}`; terminal_exit `{terminalId,code}`; terminal_gap `{terminalId,earliestSeq,latestSeq}`. They do not advance durable workspace seq. Errors correlate requestId where present; terminal commands use REST nonces so input isn't accidentally replayed on reconnect. Audit/usage/host-info/file listings are polled, not pretending all metrics are durable events; bot/run changes prompt refresh.

PushPayload is privacy-safe `{version:1,notificationId,workspaceId,conversationId,entryId,title,body,target,deepLink}` with exact NotificationTarget and token-free lemonbot:// routing (§10). APNs aps.alert plus product fields, Web Push exact JSON; previews=false generic title/body, no secret inputs/terminal output. Suppress same foreground device viewing the conversation, others unaffected. Hidden/disabled viewer suppresses OS delivery but retains inbox/attention/unread. OS permission separate from server/account configuration. Coalesce low-value completions and reconnect noise by verified task/machine, never coalesce unanswered approvals.

## 7. Backend MCP bot tools

Streamable HTTP **`/mcp` outside /v1**, JSON-RPC 2.0 MCP initialize/tools/list/tools/call/ping, protocol version `2025-03-26` (newer compatible negotiation allowed); tools/list returns the catalog below. No stdio shell/unsafe arbitrary management RPC. Each bot profile gets a random backend-issued bot bearer via profile mcpServers headers, rotated on placement/security change, stored encrypted server-side; never exposed to clients or model-visible tool output. Human session tokens cannot call bot tools, bot tokens cannot call product REST. Bot token identifies bot; optional ToolContextInput.conversationId selects only that bot's active verified invocation. Derive actual run and initiating user from backend receipt, reject ambiguous/missing live context instead of choosing another user's conversation; list_bots needs no active run but still restricted bot owner/verified invoking principal. Do not trust a conversationId as standalone authority. All target bots/groups/files/machines are constrained by initiating principal and source channel actor policy; no cross-user private bot discovery/credential lending.

All MCP results are MCPCallResult<T>, structuredContent exact result type; text is JSON serialization of same sanitized result. Tool failure returns isError true with structuredContent ErrorEnvelope; JSON-RPC invalid method/params uses standard -32601/-32602. MCP initialize/session IDs are transport-only, not resource/run IDs. Long tools use streaming HTTP response/progress, not blocking the sole Lemon control-plane socket. Persist gate/result before wait; disconnected caller may reconnect/repeat same nonce for same gate, never create another card. Cancellation/restart resolves pending waits cancelled/expired and denies action. Expiry defaults 600000 ms, expiresInMs 1000–600000. TTS/file/provider waits max 120 s then fenced unknown/error, no fake artifacts. Atomic nonce rule applies to every mutating tool; list_bots is read-only.

Tool approval **is not the execution**: request_approval returns permission for exact proposed action, bot must still execute through permitted native tool and report actual success/failure. Explicit draft Send/human step/secret input/connector consent remain independent gates. Consequential categories required ask_first override tool request. Bot->bot receipts wake specialist asynchronously and include visible source/target entry; do not wait recursively for target completion. Handoff respects requested replyConversationId only if both bots+principal authorized; otherwise deny. Attachments sent directly are authorized descriptors and copied into target destination, not raw source paths.

| Tool name | Input type | structuredContent result | Blocking | Behavior |
|---|---|---|---|---|
| `message_bot` | `MessageBotInput` | `MessageBotResult` | No; atomic receiver receipt | Wake allowed target; visible handoff and source context; returns receipt, not target completion. |
| `handoff` | `HandoffInput` | `MessageBotResult` | No; atomic receiver receipt | As message_bot with explicit task ownership; target response routed to verified originating conversation. |
| `create_draft` | `DraftToolInput` | `Draft` | No | Create editable card only. Never transmit externally. |
| `ask_user` | `AskUserInput` | `QuestionToolResult` | Yes; until terminal gate | Persist question and answers; decline/expiry yields null answers; never choose a default. |
| `request_approval` | `ApprovalToolInput` | `ApprovalToolResult` | Yes; until terminal gate | Approval only for proposed action; deny/expiry/cancellation never execute. |
| `request_human_step` | `HumanStepInput` | `HumanStepToolResult` | Yes; until terminal gate | Open machine/terminal/authorized external browser, then explicit done/skip; not remote screen control. |
| `request_secret` | `SecretToolInput` | `SecretToolResult` | Yes; until terminal gate | Write-only destination storage; result has name/saved only, never value. |
| `send_voice_memo` | `VoiceMemoInput` | `ToolEntryResult` | Yes; bounded TTS operation | Real configured TTS into immutable audio attachment and voice_memo card; unavailable if no provider. |
| `share_file` | `ShareFileInput` | `ToolEntryResult` | Yes; bounded transfer | Import node-local permitted path into ACL-bound attachment, then append result card. |
| `create_routine` | `Omit<RoutineCreate, 'botId'>` | `Routine` | Yes; platform acknowledgment | Create routine for caller bot and actual initiating user, no implicit first run. |
| `update_routine` | `RoutineUpdate & { routineId: ID }` | `Routine` | Yes; platform acknowledgment | Modify own routine only with matching revision. |
| `save_skill` | `Omit<SkillCreate, 'machineIds' \| 'botId'>` | `Skill` | Yes; destination write acknowledgment | Write SKILL.md to caller machine; shared library requires maintainer principal. |
| `list_bots` | `BotListInput` | `Page<Bot>` | No | List only bots visible to initiating user, never all swarm profiles. |
| `post_to_group` | `PostGroupInput` | `MessageReceipt` | No; append receipt | Caller must be room bot; ordinary bot posts do not recursively wake every other bot. |
| `remember` | `RememberInput` | `Memory` | Yes; owning store acknowledgment | Write selected personal/private/team scope; team sharing requires explicit intent and maintainer authority. |
| `create_bot` | `BotCreate` | `Bot` | Yes; human gate then provisioning | User must explicitly approve helper creation; policy does not turn model-suggested creation into user intent. |

### Exact MCP JSON input schemas

The following JSON Schema 2020-12 dictionary supplies **every input** plus shared definitions. For tools/list, the server materializes each tool's inputSchema as `{"$schema":"https://json-schema.org/draft/2020-12/schema","$ref":"#/$defs/<tool_name>","$defs":<the entire $defs dictionary below>}`. Thus each advertised input schema is self-contained (no network ref or implicit global defs). additionalProperties=false at every specified object; JSONObject/JSONValue permit bounded JSON only. Semantic ownership, positive revision, length/provider limits and trigger constraints above are enforced after schema validation. JSONValue recursive depth ≤32/10,000 total members/1 MiB. Tool input types in protocol.ts match these field names, discriminators, required/optional rules.

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$defs": {
    "VoiceSettings": {
      "type": "object",
      "properties": {
        "voiceId": {
          "type": "string"
        },
        "speed": {
          "type": "number",
          "minimum": 0.5,
          "maximum": 2
        },
        "language": {
          "type": [
            "string",
            "null"
          ]
        }
      },
      "required": [
        "voiceId",
        "speed",
        "language"
      ],
      "additionalProperties": false
    },
    "Field": {
      "type": "object",
      "properties": {
        "id": {
          "type": "string"
        },
        "label": {
          "type": "string"
        },
        "kind": {
          "type": "string",
          "enum": [
            "text",
            "multiline",
            "number",
            "boolean",
            "single_select",
            "multi_select"
          ]
        },
        "required": {
          "type": "boolean"
        },
        "options": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "value": {
                "type": "string"
              },
              "label": {
                "type": "string"
              }
            },
            "required": [
              "value",
              "label"
            ],
            "additionalProperties": false
          }
        },
        "min": {
          "type": "number"
        },
        "max": {
          "type": "number"
        }
      },
      "required": [
        "id",
        "label",
        "kind",
        "required"
      ],
      "additionalProperties": false
    },
    "DraftContent": {
      "oneOf": [
        {
          "type": "object",
          "properties": {
            "kind": {
              "type": "string",
              "enum": [
                "email"
              ]
            },
            "connectorId": {
              "type": "string",
              "minLength": 1,
              "maxLength": 128
            },
            "from": {
              "type": "string"
            },
            "to": {
              "type": "array",
              "items": {
                "type": "string"
              }
            },
            "cc": {
              "type": "array",
              "items": {
                "type": "string"
              }
            },
            "bcc": {
              "type": "array",
              "items": {
                "type": "string"
              }
            },
            "subject": {
              "type": "string"
            },
            "body": {
              "type": "string"
            },
            "attachmentIds": {
              "type": "array",
              "items": {
                "type": "string",
                "minLength": 1,
                "maxLength": 128
              }
            }
          },
          "required": [
            "kind",
            "connectorId",
            "from",
            "to",
            "cc",
            "bcc",
            "subject",
            "body",
            "attachmentIds"
          ],
          "additionalProperties": false
        },
        {
          "type": "object",
          "properties": {
            "kind": {
              "type": "string",
              "enum": [
                "slack"
              ]
            },
            "connectorId": {
              "type": "string",
              "minLength": 1,
              "maxLength": 128
            },
            "workspace": {
              "type": "string"
            },
            "target": {
              "type": "string"
            },
            "thread": {
              "type": [
                "string",
                "null"
              ]
            },
            "body": {
              "type": "string"
            },
            "attachmentIds": {
              "type": "array",
              "items": {
                "type": "string",
                "minLength": 1,
                "maxLength": 128
              }
            }
          },
          "required": [
            "kind",
            "connectorId",
            "workspace",
            "target",
            "thread",
            "body",
            "attachmentIds"
          ],
          "additionalProperties": false
        },
        {
          "type": "object",
          "properties": {
            "kind": {
              "type": "string",
              "enum": [
                "message"
              ]
            },
            "channelBindingId": {
              "type": "string",
              "minLength": 1,
              "maxLength": 128
            },
            "target": {
              "type": "string"
            },
            "thread": {
              "type": [
                "string",
                "null"
              ]
            },
            "body": {
              "type": "string"
            },
            "attachmentIds": {
              "type": "array",
              "items": {
                "type": "string",
                "minLength": 1,
                "maxLength": 128
              }
            }
          },
          "required": [
            "kind",
            "channelBindingId",
            "target",
            "thread",
            "body",
            "attachmentIds"
          ],
          "additionalProperties": false
        }
      ]
    },
    "RoutineTrigger": {
      "oneOf": [
        {
          "type": "object",
          "properties": {
            "kind": {
              "type": "string",
              "enum": [
                "schedule"
              ]
            },
            "cron": {
              "type": "string"
            },
            "timezone": {
              "type": "string"
            }
          },
          "required": [
            "kind",
            "cron",
            "timezone"
          ],
          "additionalProperties": false
        },
        {
          "type": "object",
          "properties": {
            "kind": {
              "type": "string",
              "enum": [
                "webhook"
              ]
            }
          },
          "required": [
            "kind"
          ],
          "additionalProperties": false
        },
        {
          "type": "object",
          "properties": {
            "kind": {
              "type": "string",
              "enum": [
                "channel_event"
              ]
            },
            "channelBindingId": {
              "type": "string",
              "minLength": 1,
              "maxLength": 128
            },
            "event": {
              "type": "string",
              "enum": [
                "mention",
                "message",
                "reaction",
                "email_received"
              ]
            },
            "channel": {
              "type": "string"
            },
            "phrase": {
              "type": "string"
            },
            "reaction": {
              "type": "string"
            },
            "senders": {
              "type": "array",
              "items": {
                "type": "string"
              }
            }
          },
          "required": [
            "kind",
            "channelBindingId",
            "event"
          ],
          "additionalProperties": false
        },
        {
          "type": "object",
          "properties": {
            "kind": {
              "type": "string",
              "enum": [
                "external_event"
              ]
            },
            "source": {
              "type": "string",
              "enum": [
                "github",
                "linear",
                "sentry",
                "pagerduty"
              ]
            },
            "eventNames": {
              "type": "array",
              "items": {
                "type": "string"
              }
            },
            "filters": {
              "type": "object",
              "additionalProperties": {
                "type": [
                  "null",
                  "boolean",
                  "number",
                  "string",
                  "array",
                  "object"
                ]
              }
            }
          },
          "required": [
            "kind",
            "source",
            "eventNames",
            "filters"
          ],
          "additionalProperties": false
        }
      ]
    },
    "Avatar": {
      "type": "object",
      "properties": {
        "kind": {
          "type": "string",
          "enum": [
            "character",
            "image"
          ]
        },
        "shape": {
          "type": "string"
        },
        "color": {
          "type": "string"
        },
        "attachmentId": {
          "type": [
            "string",
            "null"
          ]
        }
      },
      "required": [
        "kind",
        "shape",
        "color",
        "attachmentId"
      ],
      "additionalProperties": false
    },
    "message_bot": {
      "type": "object",
      "properties": {
        "clientNonce": {
          "type": "string",
          "minLength": 16,
          "maxLength": 128,
          "pattern": "^[A-Za-z0-9_-]+$"
        },
        "conversationId": {
          "type": "string",
          "minLength": 1,
          "maxLength": 128
        },
        "targetBotId": {
          "type": "string",
          "minLength": 1,
          "maxLength": 128
        },
        "text": {
          "type": "string"
        },
        "attachmentIds": {
          "type": "array",
          "items": {
            "type": "string",
            "minLength": 1,
            "maxLength": 128
          }
        },
        "replyConversationId": {
          "type": "string",
          "minLength": 1,
          "maxLength": 128
        }
      },
      "required": [
        "clientNonce",
        "targetBotId",
        "text"
      ],
      "additionalProperties": false
    },
    "handoff": {
      "type": "object",
      "properties": {
        "clientNonce": {
          "type": "string",
          "minLength": 16,
          "maxLength": 128,
          "pattern": "^[A-Za-z0-9_-]+$"
        },
        "conversationId": {
          "type": "string",
          "minLength": 1,
          "maxLength": 128
        },
        "targetBotId": {
          "type": "string",
          "minLength": 1,
          "maxLength": 128
        },
        "text": {
          "type": "string"
        },
        "attachmentIds": {
          "type": "array",
          "items": {
            "type": "string",
            "minLength": 1,
            "maxLength": 128
          }
        },
        "replyConversationId": {
          "type": "string",
          "minLength": 1,
          "maxLength": 128
        },
        "task": {
          "type": "string"
        }
      },
      "required": [
        "clientNonce",
        "targetBotId",
        "text",
        "task"
      ],
      "additionalProperties": false
    },
    "create_draft": {
      "type": "object",
      "properties": {
        "clientNonce": {
          "type": "string",
          "minLength": 16,
          "maxLength": 128,
          "pattern": "^[A-Za-z0-9_-]+$"
        },
        "conversationId": {
          "type": "string",
          "minLength": 1,
          "maxLength": 128
        },
        "content": {
          "$ref": "#/$defs/DraftContent"
        }
      },
      "required": [
        "clientNonce",
        "content"
      ],
      "additionalProperties": false
    },
    "ask_user": {
      "type": "object",
      "properties": {
        "clientNonce": {
          "type": "string",
          "minLength": 16,
          "maxLength": 128,
          "pattern": "^[A-Za-z0-9_-]+$"
        },
        "conversationId": {
          "type": "string",
          "minLength": 1,
          "maxLength": 128
        },
        "title": {
          "type": "string"
        },
        "fields": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/Field"
          }
        },
        "expiresInMs": {
          "type": "integer",
          "minimum": 1000,
          "maximum": 600000
        }
      },
      "required": [
        "clientNonce",
        "title",
        "fields"
      ],
      "additionalProperties": false
    },
    "request_approval": {
      "type": "object",
      "properties": {
        "clientNonce": {
          "type": "string",
          "minLength": 16,
          "maxLength": 128,
          "pattern": "^[A-Za-z0-9_-]+$"
        },
        "conversationId": {
          "type": "string",
          "minLength": 1,
          "maxLength": 128
        },
        "category": {
          "type": "string",
          "enum": [
            "shell",
            "files",
            "external_message",
            "calendar",
            "publish",
            "purchase",
            "permissions",
            "connector",
            "handoff"
          ]
        },
        "title": {
          "type": "string"
        },
        "description": {
          "type": "string"
        },
        "target": {
          "type": "string"
        },
        "inputs": {
          "type": "object",
          "additionalProperties": {
            "type": [
              "null",
              "boolean",
              "number",
              "string",
              "array",
              "object"
            ]
          }
        },
        "expiresInMs": {
          "type": "integer",
          "minimum": 1000,
          "maximum": 600000
        }
      },
      "required": [
        "clientNonce",
        "category",
        "title",
        "description",
        "target",
        "inputs"
      ],
      "additionalProperties": false
    },
    "request_human_step": {
      "type": "object",
      "properties": {
        "clientNonce": {
          "type": "string",
          "minLength": 16,
          "maxLength": 128,
          "pattern": "^[A-Za-z0-9_-]+$"
        },
        "conversationId": {
          "type": "string",
          "minLength": 1,
          "maxLength": 128
        },
        "title": {
          "type": "string"
        },
        "instructions": {
          "type": "string"
        },
        "reason": {
          "type": "string",
          "enum": [
            "login",
            "mfa",
            "captcha",
            "payment",
            "identity",
            "other"
          ]
        },
        "externalUrl": {
          "type": "string"
        },
        "expiresInMs": {
          "type": "integer",
          "minimum": 1000,
          "maximum": 600000
        }
      },
      "required": [
        "clientNonce",
        "title",
        "instructions",
        "reason"
      ],
      "additionalProperties": false
    },
    "request_secret": {
      "type": "object",
      "properties": {
        "clientNonce": {
          "type": "string",
          "minLength": 16,
          "maxLength": 128,
          "pattern": "^[A-Za-z0-9_-]+$"
        },
        "conversationId": {
          "type": "string",
          "minLength": 1,
          "maxLength": 128
        },
        "name": {
          "type": "string"
        },
        "description": {
          "type": "string"
        },
        "scope": {
          "type": "string",
          "enum": [
            "machine",
            "bot"
          ]
        },
        "expiresInMs": {
          "type": "integer",
          "minimum": 1000,
          "maximum": 600000
        }
      },
      "required": [
        "clientNonce",
        "name",
        "description",
        "scope"
      ],
      "additionalProperties": false
    },
    "send_voice_memo": {
      "type": "object",
      "properties": {
        "clientNonce": {
          "type": "string",
          "minLength": 16,
          "maxLength": 128,
          "pattern": "^[A-Za-z0-9_-]+$"
        },
        "conversationId": {
          "type": "string",
          "minLength": 1,
          "maxLength": 128
        },
        "text": {
          "type": "string"
        },
        "voice": {
          "$ref": "#/$defs/VoiceSettings"
        }
      },
      "required": [
        "clientNonce",
        "text"
      ],
      "additionalProperties": false
    },
    "share_file": {
      "type": "object",
      "properties": {
        "clientNonce": {
          "type": "string",
          "minLength": 16,
          "maxLength": 128,
          "pattern": "^[A-Za-z0-9_-]+$"
        },
        "conversationId": {
          "type": "string",
          "minLength": 1,
          "maxLength": 128
        },
        "path": {
          "type": "string"
        },
        "filename": {
          "type": "string"
        },
        "caption": {
          "type": "string"
        }
      },
      "required": [
        "clientNonce",
        "path"
      ],
      "additionalProperties": false
    },
    "create_routine": {
      "type": "object",
      "properties": {
        "clientNonce": {
          "type": "string",
          "minLength": 16,
          "maxLength": 128,
          "pattern": "^[A-Za-z0-9_-]+$"
        },
        "name": {
          "type": "string"
        },
        "instruction": {
          "type": "string"
        },
        "trigger": {
          "$ref": "#/$defs/RoutineTrigger"
        },
        "enabled": {
          "type": "boolean"
        }
      },
      "required": [
        "clientNonce",
        "name",
        "instruction",
        "trigger",
        "enabled"
      ],
      "additionalProperties": false
    },
    "update_routine": {
      "type": "object",
      "properties": {
        "clientNonce": {
          "type": "string",
          "minLength": 16,
          "maxLength": 128,
          "pattern": "^[A-Za-z0-9_-]+$"
        },
        "routineId": {
          "type": "string",
          "minLength": 1,
          "maxLength": 128
        },
        "revision": {
          "type": "integer"
        },
        "name": {
          "type": "string"
        },
        "instruction": {
          "type": "string"
        },
        "trigger": {
          "$ref": "#/$defs/RoutineTrigger"
        },
        "enabled": {
          "type": "boolean"
        }
      },
      "required": [
        "clientNonce",
        "routineId",
        "revision"
      ],
      "additionalProperties": false
    },
    "save_skill": {
      "type": "object",
      "properties": {
        "clientNonce": {
          "type": "string",
          "minLength": 16,
          "maxLength": 128,
          "pattern": "^[A-Za-z0-9_-]+$"
        },
        "name": {
          "type": "string"
        },
        "description": {
          "type": "string"
        },
        "markdown": {
          "type": "string"
        },
        "scope": {
          "type": "string",
          "enum": [
            "personal",
            "team"
          ]
        }
      },
      "required": [
        "clientNonce",
        "name",
        "description",
        "markdown",
        "scope"
      ],
      "additionalProperties": false
    },
    "list_bots": {
      "type": "object",
      "properties": {
        "query": {
          "type": "string"
        },
        "limit": {
          "type": "integer",
          "minimum": 1,
          "maximum": 200
        },
        "cursor": {
          "type": "string"
        }
      },
      "required": [],
      "additionalProperties": false
    },
    "post_to_group": {
      "type": "object",
      "properties": {
        "clientNonce": {
          "type": "string",
          "minLength": 16,
          "maxLength": 128,
          "pattern": "^[A-Za-z0-9_-]+$"
        },
        "groupConversationId": {
          "type": "string",
          "minLength": 1,
          "maxLength": 128
        },
        "text": {
          "type": "string"
        },
        "attachmentIds": {
          "type": "array",
          "items": {
            "type": "string",
            "minLength": 1,
            "maxLength": 128
          }
        },
        "mentions": {
          "type": "array",
          "items": {
            "type": "string",
            "minLength": 1,
            "maxLength": 128
          }
        }
      },
      "required": [
        "clientNonce",
        "groupConversationId",
        "text"
      ],
      "additionalProperties": false
    },
    "remember": {
      "type": "object",
      "properties": {
        "clientNonce": {
          "type": "string",
          "minLength": 16,
          "maxLength": 128,
          "pattern": "^[A-Za-z0-9_-]+$"
        },
        "conversationId": {
          "type": "string",
          "minLength": 1,
          "maxLength": 128
        },
        "text": {
          "type": "string"
        },
        "kind": {
          "type": "string",
          "enum": [
            "fact",
            "preference",
            "instruction",
            "summary"
          ]
        },
        "scope": {
          "type": "string",
          "enum": [
            "personal",
            "team",
            "private_note"
          ]
        }
      },
      "required": [
        "clientNonce",
        "text",
        "kind",
        "scope"
      ],
      "additionalProperties": false
    },
    "create_bot": {
      "type": "object",
      "properties": {
        "clientNonce": {
          "type": "string",
          "minLength": 16,
          "maxLength": 128,
          "pattern": "^[A-Za-z0-9_-]+$"
        },
        "name": {
          "type": "string"
        },
        "machineId": {
          "type": "string",
          "minLength": 1,
          "maxLength": 128
        },
        "title": {
          "type": "string"
        },
        "job": {
          "type": "string"
        },
        "instructions": {
          "type": "string"
        },
        "avatar": {
          "$ref": "#/$defs/Avatar"
        },
        "voice": {
          "$ref": "#/$defs/VoiceSettings"
        },
        "language": {
          "type": [
            "string",
            "null"
          ]
        },
        "visibility": {
          "type": "string",
          "enum": [
            "personal",
            "team"
          ]
        },
        "skillIds": {
          "type": "array",
          "items": {
            "type": "string",
            "minLength": 1,
            "maxLength": 128
          }
        },
        "templateId": {
          "type": "string",
          "minLength": 1,
          "maxLength": 128
        }
      },
      "required": [
        "clientNonce",
        "name",
        "machineId"
      ],
      "additionalProperties": false
    }
  }
}

```

## 8. Client information architecture and behavior

Screen IDs are shared navigation destinations, **not extra REST paths**. All three clients implement every screen below with adaptive navigation (macOS/web resizable Bot-centric sidebar + selected content + optional detail pane; iOS NavigationStack/tab or compact drawer). Do not copy a generic fixed Chat/Skills/Computer left-nav in place of Bot roster. Privileged controls obey ACL rather than platform-based hidden scope cuts. Desktop-only OS input-device selection and iOS camera/share extension are truthful platform differences; same API editing/testing/attaching/policies are available on phone where user authorized. Disabled provider/push/adapter states have reason + setup/open OS settings, not stub screens.

| Screen ID | Required surfaces and interactions | API/card bindings |
|---|---|---|
| onboarding | Backend URL picker; setup-code owner bootstrap OR email/password sign-in/invite acceptance; educational persistent teammate/jobs/shared-machine warning; role suggestions/custom first bot; attach pending/online/errors; notification permission; finish only with real bot/machine | setup, auth, machines, bots, devices, capabilities |
| sidebar | Bots/groups; pinned/unassigned/user sections with reorder/collapse/rename/delete; hidden list; unread filter/mark; needs-input/working/offline indicators; New bot/group; account switch/sign out and settings | bots/sidebar, sections, conversations/read, notifications |
| conversation | Incremental transcript and unread divider, attribution, card actions, activity/tool detail, history pagination/jump, reply/reaction/feedback, composer/staged files/references, error tray/copy request ID, Stop and steer | conversations, entries, runs, attachments; complete cards.md |
| bot.create | Suggested role/template picker, custom name/title/job/instructions/avatar, machine choice/shared-host consent, creating/unknown/failure preserve input | bots, templates/import, machines |
| bot.edit | Same identity/job/voice/language/avatar with crop/character/upload/generate, owner/manager and shared setup; duplicate/rescope; explicit team-copy selection; delete preview | bots/:id, avatar/generate, duplicate/team-copy/preview |
| bot.settings | Details/Media/assigned Machine, routines/memory/reference files, notify toggle, connectors/skills, manager grant/publish/unpublish/required restrictions | bots/sidebar, routines, memory, connectors, attachments |
| group.create | 2–6 bot multi-picker, humans, lead, editable name, usage/shared-history warning; group members/details edit; preserve draft on uncertain create | conversations create/update, bots |
| machines | Online/offline/pending/revoked inventory, last seen, attached machine bot count, attach button, consent/access ownership | machines list |
| machine.attach | Named machine, one-use copy join command/code, expiry/reissue/cancel, provider/cwd/service instructions, waiting→online, repair same identity | machines POST/reconnect/invites + machine.upserted |
| machine.detail | Host-info cpu/memory/disk/version/user/cwd/time; bots on host; shared-access warning; files/terminal/secrets tabs; access-user edit; reconnect/detach preview/exact-name | machines/host, bots?machineId, machine files/secrets, terminals |
| machine.files | Breadcrumb/list/hidden, stat/preview/download/upload/new folder/rename/move/delete preview; size/type/error/truncation, host path scope explicit | node file product endpoints, files/import, attachments |
| machine.terminal | Full-access confirmation, cwd/size, VT-compatible PTY view/input/resize, disconnect grace/gap/exit/close; no fake web terminal | terminals + WS terminal frames |
| machine.secrets | Names/descriptions/scope only, masked add/replace, delete confirmation and real failure; bot-shared exposure warning | secrets; secret_request |
| skills | Library personal/team/provenance, search, enabled, markdown name/description/editor, explicit installation machines, upload text into editor, add to bot | skills, bots.skillIds; SCM/connector pointers |
| routines | Global own and bot detail list, name/active/paused/next run/schedule words/timezone; instruction/trigger editor, seeded chat edit, test real work, run history/error, delete preview, webhook key issuance/rotate/copy/revoke | routines, routine-runs, event-sources, webhook_key |
| memory | Bot selected scopes (personal/team/private note), list/search/details/add/correct/delete/import/export; explicit team sharing and stale-fact caution | bots/memory, memory/:id |
| search | Command/jump palette and filters All/Messages/Bots/Groups/Files/Routines/Skills/Memory, in-conversation find/jump; no hidden content snippets | search, entries/:id |
| inbox | Durable needs-input/result/error/machine notifications; read/unread, dismiss/clear-only notices, jump to targeted actionable card; OS permission/config diagnostics | notifications + gate endpoints |
| settings.account | Display/email/avatar/password/session devices, account switching (device-local), preferences appearance/language/timezone/color/side-by-side, delete with reauth and typed confirmation | me, auth/sessions, devices, me/preview |
| settings.workspace | Workspace name/timezone/owner transfer/enabled; members/roles/enable/invites/revoke/removal preview, published Team directory/access | workspace, members, invites, bots visibility team |
| settings.notifications | Global enabled/sound/previews/completed/needsInput; OS permission recovery, APNs/Web Push status, bot toggles; per-device registration | me.notifications, devices, capabilities, sidebar |
| settings.voice | Voice/speed/language preview, mic permission and local input device selection, on-device/backend capability indicators | me.preferences.voice, audio/speech, capabilities |
| settings.policies | Effective ask_first/auto_review/allow category rules, locked required vs personal, local ceiling, MCP origin policy, public templates, clear own connector grants, attention queue | policies/rules, consents, approvals |
| settings.usage | Tokens/cost/unknown-price/incomplete data by bot/routine/user/day/source with range, routine/group/handoff attribution; no billing plans | usage |
| settings.about | Product/client/swarm versions, API version, platform, copy diagnostics request/conversation IDs + timestamps/attempts; operator update instructions/service connection | setup, capabilities, machines/host; no automatic node-image reset |
| connect.apps | Bot MCP server inventory/installed vs connected/auth needed/blocked, custom HTTPS server configuration, per-tool disable, labeled account switch/reconnect, grants, provider external auth; channels separate setup | connectors/auth/consents, channels, skills |
| templates | Workspace/public detail/provenance/terms/instructions/skills/routines review/import, export/update/audience/revoke; never shares original Bot's history | templates, bots/export/import; bot_template_share |
| file.viewer | Image/video/audio/PDF/text/Markdown/JSON/grid/docx, isolated HTML/download fallback, original download; loading/not found/too big/render failure states | attachment metadata/download + preview type |
| voice.overlay | Empty-composer start, connecting/active/failed, mute/hangup/transcript/settings, return while visiting another chat, existing-call End and chat confirmation, duration/feedback summary | voice/sessions, STT/message/TTS loop, voice_call, voice_memo |

macOS/web shortcuts: Cmd (macOS)/Ctrl (web OS) K palette, Shift+F Bots search, N new, F in-chat find, B sidebar, I/L focus composer, 1–9 selected sidebar bots, Alt+Up/Down previous/next, [/] history, Shift+M or Shift+W connect apps/skills, Shift+, Bot settings, comma settings, Enter send/Shift+Enter newline, modifier+Enter send, D dictation. Voice start button only. Web must not intercept reserved browser shortcuts destructively; expose equivalent buttons. iOS long-press supports pin/hide/section/read/delete, camera/file picker/share extension drafts; Voice uses OS audio-session policies, no background continuity promise.

Every UI shows honest unavailable/unknown state, not fake success/demo data. Activity is distinct from transcript, no cached running truth without reconciliation. Keyboard/accessibility/reduced-motion/light-dark-system/nonce/error-ID behavior shared. Configured generic OIDC/SCIM, directory policy, provider integrations and owned-host management in §11 are real product scope; do not hard-code vendor SSO/subscription rules. Vendor payment wallets/dev galleries/1Password/cookie copying/remote desktop/teaching capture remain excluded/mapped in cards/coverage. §10 adds all 16 Muse companion/control features without ambient capture.

## 9. Concrete wire examples and implementation boundary

Create: `POST /v1/bots` → `Bot`, JSON `{"clientNonce":"01LEMONBOTCREATE0000000000","name":"Finance","machineId":"machine_1","job":"Reconcile weekly expenses","instructions":"Prepare drafts; ask before external changes."}`.

Send: `POST /v1/conversations/c_1/messages` → 202 MessageReceipt, JSON `{"clientNonce":"01LEMONBOTMESSAGE000000000","text":"Review these receipts","attachmentIds":["attachment_1"],"mode":"followup"}`. Response includes real durable entries/run IDs immediately, never a synthetic completed assistant answer.

Resolve: `POST /v1/approvals/a_1/resolve`, JSON `{"clientNonce":"01LEMONBOTAPPROVE000000000","revision":1,"decision":"approve_once"}` → Approval gate approved, not proof proposed action completed.

Draft Send: `POST /v1/drafts/d_1/send`, JSON `{ "clientNonce":"01LEMONBOTSENDDRAFT00000000", "revision":2, "content":{"kind":"email","connectorId":"connector_1","from":"finance@example.org","to":["reviewer@example.org"],"cc":[],"bcc":[],"subject":"Expense review","body":"Please review attached receipts.","attachmentIds":[]} }` → Draft sending, then draft.upserted sent only after verification.

Machine attach: `POST /v1/machines`, JSON `{"clientNonce":"01LEMONBOTATTACH0000000000","name":"Office Mac","nodeName":"office-mac","labels":{"purpose":"finance"}}` → MachineAttachResult; joinCommand server-issued, not a browser-held operator token.

All additional exact field contracts are the exported request/response types in the endpoint table, with all discriminated payloads in protocol.ts. `RestRequest<K>`, `RestResponse<K>` and `RestQuery<K>` are SDK generics; Swift mirrors concrete unions and nullability. No runtime imports in protocol.ts, no shared implementation-side state. Backend owns SQLite product persistence/ACL/nonces/event cursor/push/MCP, delegates Lemon runtime/profile/cron/memory/node operations to canonical services, reconciles full terminal history, and never starts a parallel swarm/router/scheduler. Platform capability discovery gates missing RPCs with explicit errors. This document does not claim root runtime extensions or all clients already implement the contract.

## 10. Companion, control, and all 16 Muse adaptations

These are normative additions to the v1 catalog, implemented on every client with the platform differences stated here. They do not replace the Bot roster, profile-scoped privacy or runtime. Types are exported by protocol.ts. Same §1 errors/nonces/revisions, plus listed codes; status 200 reads/updates/preview/ack/voice sample, 201 new reminders/preferences/connectors, 202 reset/long operation if not terminal.

| Method/path under /v1 | Request | Response | Query | Required role / ACL | Additional errors |
|---|---|---|---|---|---|
| `GET /bots/:id/overview` | `undefined` | `BotOverview` | `undefined` | Member (visible/owned scopes only) | policy_denied, capability_unavailable, upstream_unavailable |
| `GET /bots/:id/presence` | `undefined` | `BotPresence` | `undefined` | Member (visible/owned scopes only) | policy_denied, capability_unavailable, upstream_unavailable |
| `GET /machines/:id/capabilities` | `undefined` | `MachineCapabilities` | `undefined` | Machine | capability_unavailable, machine_offline |
| `GET /bots/:id/grants` | `undefined` | `Page<BotGrant>` | `PageQuery` | Member visible bot (GET) / Manage bot (PATCH) | policy_denied, capability_unavailable |
| `PATCH /bots/:id/grants/:grantId` | `BotGrantUpdate` | `BotGrant` | `undefined` | Member visible bot (GET) / Manage bot (PATCH) | policy_denied, capability_unavailable |
| `GET /activity` | `undefined` | `Page<ActivityItem>` | `ActivityQuery` | Member (visible/owned scopes only) | policy_denied, capability_unavailable, upstream_unavailable |
| `GET /upcoming` | `undefined` | `Page<UpcomingItem>` | `UpcomingQuery` | Member (visible/owned scopes only) | policy_denied, capability_unavailable, upstream_unavailable |
| `GET /bots/:id/activity` | `undefined` | `Page<ActivityItem>` | `ActivityQuery` | Member (visible/owned scopes only) | policy_denied, capability_unavailable, upstream_unavailable |
| `GET /bots/:id/upcoming` | `undefined` | `Page<UpcomingItem>` | `UpcomingQuery` | Member (visible/owned scopes only) | policy_denied, capability_unavailable, upstream_unavailable |
| `GET /reminders` | `undefined` | `Page<Reminder>` | `PageQuery & { botId?: ID }` | Own | conflict, expired |
| `POST /reminders` | `ReminderCreate` | `Reminder` | `undefined` | Own | conflict, expired |
| `DELETE /reminders/:id` | `Update` | `Reminder` | `undefined` | Own | conflict, expired |
| `GET /bots/:id/preference-changes` | `undefined` | `Page<PreferenceChange>` | `PageQuery` | Manage bot / Own private scope | revision_conflict, confirmation_required, expired, machine_offline, outcome_unknown |
| `POST /bots/:id/preference-changes` | `PreferenceChangeCreate` | `PreferenceChange` | `undefined` | Manage bot / Own private scope | revision_conflict, confirmation_required, expired, machine_offline, outcome_unknown |
| `POST /preference-changes/:id/undo` | `PreferenceUndo` | `PreferenceChange` | `undefined` | Manage bot / Own private scope | revision_conflict, confirmation_required, expired, machine_offline, outcome_unknown |
| `POST /bots/:id/reset` | `BotReset` | `BotResetResult` | `undefined` | Bot owner + Machine | confirmation_required, conflict, machine_offline, outcome_unknown |
| `POST /bots/:id/memory/import/preview` | `MemoryImportPreviewRequest` | `MemoryImportPreview` | `undefined` | Manage bot / Own private scope | revision_conflict, confirmation_required, expired, machine_offline, outcome_unknown |
| `GET /bots/:id/ideas` | `undefined` | `BotIdea[]` | `undefined` | Member (visible/owned scopes only) | policy_denied, capability_unavailable, upstream_unavailable |
| `POST /bots/:id/voice/preview` | `VoicePreviewRequest` | `SpeechResult` | `undefined` | Member (visible bot) | capability_unavailable, upstream_unavailable, unsupported_media |
| `GET /bots/:id/milestones` | `undefined` | `Page<Milestone>` | `PageQuery` | Own | conflict, expired |
| `POST /milestones/:id/ack` | `Mutation` | `Milestone` | `undefined` | Own | conflict, expired |
| `POST /bots/:id/connectors/setup` | `ConnectorSetupRequest` | `ConnectorSetupResult` | `undefined` | Bot owner + Machine | confirmation_required, conflict, machine_offline, outcome_unknown |
| `POST /connectors/:id/preview` | `PreviewRequest` | `Confirmation` | `undefined` | Own target resource | revision_conflict, confirmation_required |
| `POST /attachments/:id/preview` | `PreviewRequest` | `Confirmation` | `undefined` | Own target resource | revision_conflict, confirmation_required |
| `POST /memory/:id/preview` | `PreviewRequest` | `Confirmation` | `undefined` | Manage bot / Own private scope | revision_conflict, confirmation_required, expired, machine_offline, outcome_unknown |

### Presence anchor, capability table, Activity + Upcoming

All clients keep one visible Bot identity/status anchor with assigned machine label. Click header/avatar opens **bot.overview** with current task/run, recent Activity, Upcoming, Ideas, grants and separate Identity / Job / Memory tabs. BotPresence.status is idle/working/making/needs_input/offline (UI labels “Needs input”); Bot.activity matches it. Conversation reading/typing is finer per-session activity, not a different durable identity. “making” requires actual artifact-generation tool/run evidence (evidenceEntryId), never a timer/animation; ordinary research/action is working. Needs-input takes precedence over active-making; inaccessible host is offline with stale=true even if last retained run was working. Health machineStatus is separate from activity. Bot overview returns latest 20 activity/next 20 upcoming, with their cursors for full pages.

MachineCapabilities lists actual configured capabilities and measured OS grants (off/read_only/read_interact, supported, tools, reason, measuredAtMs, stale). Offline inspection returns last measured rows explicitly stale; never turns unknown into permission. Relevant Mac host requests its own TCC, not remote iOS/web; Linux never shows invented Apple Calendar grants. BotGrant effectiveLevel is min(requestedLevel, machine configured level, OS grant, effective required product policy), order off < read_only < read_interact. Unsupported/missing grant yields off. PATCH requested grants requires maintainer and actual mapped native tool-policy support; unsupported mapping capability_unavailable, no purely cosmetic security switch. Machine OS permission is not Bot permission and no host sandbox claim.

ActivityItem is sanitized chronological user-visible run/tool/approval/preference/memory/artifact/enrollment facts with bot/run/task/conversation/machine provenance. Default descending occurredAtMs,id; workspace activity filters bot/machine/time and never leaks private DMs, even to admins. Per-bot equivalent enforces same ACL, path botId cannot be overridden by query. Upcoming merges enabled owned routine nextRunAtMs and caller reminders, ascending dueAtMs,id; from defaults now, to defaults +30 days, max 366 days; timezone/last outcome/offline blockedReason explicit. A task conversation is not a run. Reminder is a one-off durable **notification**, not an agent scheduling engine; bot+user+conversation scoped, deliver once as result notification at dueAtMs, cancellation prevents future delivery, backend timer/outbox handles notification due-time only. Agent recurring work still Lemon cron. Existing task run may continue beyond due time; Upcoming does not fabricate completed work.

### Plain-language action reviews and Identity / Job / Memory

Approval.scope is ReviewScope: scope badge once/run/site/connector, target Bot+machine labels, exact origin/connector/run, expiry and concrete consequences. Native exec defaults once; run/site/connector contexts explain bounded proposal, not broader automatic grant. Financial/destructive/permission-changing/external-message gates never show blanket Always allow; future rules only when true narrower supported policy, never revive expired proposal. Phone notification links exact request, not a generic approve screen.

Identity tab edits name/title/avatar/voice/language via bot update; Job tab edits Job/instructions/style/boundaries, effective hard policy separately; Memory tab handles scoped facts. Every Job/voice/language change (manual or natural language) creates PreferenceChange with before/after/source/reason/user/machine and resulting Bot revision. Natural-language “be more concise” uses MCP update_preferences **only** with actual authorized user sourceEntryId (external/email/tool text cannot attest intent). One preference scope per create (job+instructions together, OR voice, OR language); revision is Bot revision. Undo request carries PreferenceChange revision and current botRevision, rejects if changed fields no longer match recorded after or another change intervened; restores before through profiles.update/scoped settings, increments Bot/change revisions, state undone. No SOUL.md duplicate store, no cross-bot personalization. Memory corrections are inspectable Memory resources, not unsafe unrestricted systemPrompt mutation.

### Destructive scopes and guided memory import

Every Confirmation now also includes affected:ScopeEffect[] with exact resource IDs, operation delete/revoke/reset/move/retain, machine attribution and residual-data explanation. Do not expose inaccessible private content in preview. DELETE attachments/memory/connectors requires corresponding preview + Confirm; memory preview action forget, connector action disconnect, attachment action delete. Removing conversation leaves independently derived memory; forgetting selected memory leaves transcript/backups; disconnect revokes connector/grant and future tool access but leaves history/artifacts, provider authorization revocation reported only after real provider acknowledgment. Bot reset preview uses POST bots/:id/preview `{action:"reset",resetScopes:[…],clientNonce}`, binds selected scope candidates and current revision, followed by POST reset BotReset with same scopes/token/exact bot name. Scopes conversations/memory/job/routines/connectors/attachments can be selected independently, no hidden defaults. Preserve identity/machine and unselected scopes; shared machine filesystem/browser/provider credentials never implicitly wiped. Scope conversations resets caller-visible conversations only (Team owner may not destroy private teammate DMs without explicit admin-wide deletion authority/preview); job reset empties job/instructions, routines removes owned future jobs, connector revokes exact configured owned/shared rights. BotResetResult lists acknowledged removedIds/retainedScopes, unknown receipts fence retries.

Guided import accepts exactly one of text (≤1 MiB) or own ready attachment, scope personal/team/private_note and supported format facts_text/lemon_memory_json/chat_export_zip. Preview never writes memory. Facts document contains explicit durable statements (one paragraph/item), JSON matches MemoryExport items and excludes unknown/credential fields, ZIP safely bounded to 25 MiB compressed/100 MiB expanded/200 files, rejects traversal/symlinks/encryption/zip bombs. Supported ZIP entries: facts.txt/facts.md/memory.json and ChatGPT conversations.json exports; chat exports propose **explicit user-authored remember/preference declarations**, not full chat replay or inferred third-party personal profiles. Unknown entries/undurable statements/duplicates/secrets are listed as exclusions with scrubbed summaries. Parse failure unsupported_media/invalid_request, no fake extracted facts. Candidate IDs/provenance/sourceSha256, bot/machine/scope, exclusions and 10-minute token are immutable preview. All candidates selectedByDefault false. User checks/reviews exact candidates (up to 200), confirms selectedCandidateIds+preview revision/token. Selected text immutable; user edits facts document to re-preview for corrections. Recheck placement/ACL/source digest before scoped memory.add. MemoryImportResult completed only acknowledged items; partial unknown fenced with failedCandidateIds and stable created IDs. No unreviewed POST items path remains.

### Ideas, deliverables, voice and compact summon

GET bot ideas returns ≤6 curated deterministic useful prompts from Job, installed skills/connector inventory and effective capabilities. Each BotIdea states expectedOutput/dependencies/ready/blockedReasons; offline/config missing truthful. Selecting inserts prompt/references in composer, **never starts work until Send**. No personalized infinite feed/model hidden actions. Every Attachment.provenance carries generating bot/run/machine/sourceEntry/generatedAtMs when generated or node-imported; user uploads use known nullable fields (null means not bot-generated). Completed Run/artifact evidence, not motion, controls making and outcome UI.

VoicePreviewRequest returns SpeechResult for fixed non-sensitive sample **“Hello, I’m your Lemon Bot teammate. Ready when you are.”**, using bot voice or explicit override; no run/conversation created. Configured actual TTS required (on-device preview allowed client fallback clearly labelled). macOS configurable push-to-talk shortcut: hold to capture, release to transcribe into **unsent reviewable** composer, Escape discards; visible selected bot+machine/mic ownership and optional mic-on/off cues. Web/iOS explicit mic/stop/cancel states, audio device picker where available, no ambient listening/wake words/background phone guarantee. Voice chat may send finalized utterances only while explicit active-call mode visible; ordinary dictation/PTT never auto-sends. Same text ACLs/approvals/placement apply.

ClientLocalSettings is device-local: summonShortcut/PTT (null disabled), mic cues true default, selectedBotId, compactCompanionEnabled false, reducedMotion system. macOS global summon opens one mini-composer/optional single selected-bot menu-bar companion, **not one floating pet per bot**; full app carries same composer nonce journal. Add selected text/file/explicit share only on user action; no automatic clipboard history/screen reading/background capture. iOS share extension user-chosen photo/file/link/text → same staging composer; web in-app command palette. All show bot+machine and account target before Send.

MessageReceipt.delivery reports requestedMode vs actual effectiveMode per bot: queued (waiting separate turn), steering (worker acknowledged update to targetRunId), interrupting (cancellation requested/new turn pending), started (new acknowledged run), outcome_unknown (not safe to resend). If runtime cannot steer and queues follow-up, UI says **Queued**, not “steering”. Steering references existing run, does not fabricate a second executing task; receipt associated runId is that actual run. Followup is default; task conversation keeps separate work, same assigned host. No arbitrary other DM context injection.

### Task-aware links, milestones and enrollment

Notification/PushPayload includes target and deepLink, always consistent with nullable convenience IDs. URI grammar (IDs percent-encoded, no slash or credentials):

- `lemonbot://workspace/<workspaceId>/bot/<botId>?conversationId=<id>&taskConversationId=<id>&entryId=<id>` (optional query IDs only when present); target entry.
- `lemonbot://workspace/<workspaceId>/bot/<botId>?conversationId=<id>&entryId=<id>&approvalId=<id>`; target approval.
- `lemonbot://workspace/<workspaceId>/machine/<machineId>`; target machine, optional `botId` query.
- `lemonbot://workspace/<workspaceId>/bot/<botId>/routine/<routineId>?routineRunId=<id>`; target routine.

Reject unknown host/path/query, encoded separators/unsafe schemes, mismatched IDs and foreign workspace; select saved backend+account by known workspace ID, require login if absent, then fetch and authorize all IDs. URI is navigation **not approval**, never contains bearer/operator token/provider secrets or arbitrary server URL. Web maps same grammar to same-origin `/app/workspace/...` path with same query, native push opens LemonBotKit router; deleted/revoked target renders unavailable, not another user's content. TaskConversationId is the existing task conversation ID, not a second task entity. Notification suppression/coalescing never hides pending decision; offline machine state not “Bot thinking”.

Milestones unique `(botId,userId,kind)` for machine_attached (actual verified online placement), first_routine_success (terminal succeeded), first_approved_task_completed (approved then verified terminal succeeded). Store evidenceId server-side once, never award copied command/request acceptance/model claim. GET per bot and milestone.upserted; POST ack atomically persists acknowledgedAtMs across devices. Clients may render one tiny nonblocking celebration only after acquiring ack with own nonce; concurrent different nonce sees already acknowledged and does not animate. Preferences.celebrationsEnabled default true, false disables display (still records outcome); reduced motion replaces motion/confetti with static checkmark, no engagement levels/constant effects. No notification/success blocked waiting for animation.

Machine enrollment UI shows invited/waiting-for-join/connecting/verifying/online or expired/failed/revoked based only actual invite/controller facts; installing label only with observed installer progress, otherwise waiting. Purpose/labels/name/one-use command and explicit trusted-host acceptance visible. Copy does not prove joined. Last-seen/host service stopped/offline distinct from closed client. No Home Link/BLE/custom hardware dependency.

Connector setup validates machineId equals bot's current assignment, explicitly chosen name/url/account/shared/read-only-or-interact level. secretBindings maps headers to existing names from node.secrets.list; write values separately via names-only/masked host secret route, never raw header values in setup or transcript. For HTTP profile MCP config, preserve exact `${LEMON_SECRET:NAME}` references; prefix/suffix e.g. `Bearer ${LEMON_SECRET:NAME}` allowed by destination resolver; only destination encrypted Secrets store resolves, no env/external fallback, missing/malformed/failing reference fails before clients attach with secret_resolution_failed (sanitized product capability/upstream error). Controller persistence/codec retains references unchanged. Secrets never returned as config values; shared Bot grants never inferred from account metadata. OAuth service credentials remain encrypted in appropriate account/host provider custody; no operator-token reuse. API setup result secretNames is names-only and actual effective grants.

New durable events, same exact RealtimeEvent envelope/ACL and resource revision rules:

| Event | Payload |
|---|---|
| bot.presence | BotPresence |
| grant.upserted | BotGrant |
| activity.upserted | ActivityItem |
| reminder.upserted | Reminder |
| reminder.deleted | Deleted |
| preference_change.upserted | PreferenceChange |
| milestone.upserted | Milestone |

Additional MCP tools: update_preferences (PreferenceToolInput→PreferenceChange), blocking until acknowledged profiles.update, and create_reminder (ReminderToolInput→Reminder), blocking until persisted notification schedule. Existing bot token/context/nonce rules apply; explicit user sourceEntryId for preference proves referenced **user intent**, never model authority. Exact new input schemas (self-contained):

```json
{"update_preferences":{"type":"object","additionalProperties":false,"required":["clientNonce","revision","changes","reason","sourceEntryId"],"properties":{"clientNonce":{"type":"string","minLength":16,"maxLength":128,"pattern":"^[A-Za-z0-9_-]+$"},"conversationId":{"type":"string"},"revision":{"type":"integer","minimum":1},"sourceEntryId":{"type":"string"},"reason":{"type":"string"},"changes":{"type":"object","additionalProperties":false,"properties":{"job":{"type":"string"},"instructions":{"type":"string"},"voice":{"type":"object","additionalProperties":false,"required":["voiceId","speed","language"],"properties":{"voiceId":{"type":"string"},"speed":{"type":"number","minimum":0.5,"maximum":2},"language":{"type":["string","null"]}}},"language":{"type":["string","null"]}}}}},"create_reminder":{"type":"object","additionalProperties":false,"required":["clientNonce","text","dueAtMs","timezone"],"properties":{"clientNonce":{"type":"string","minLength":16,"maxLength":128,"pattern":"^[A-Za-z0-9_-]+$"},"conversationId":{"type":"string"},"text":{"type":"string"},"dueAtMs":{"type":"integer","minimum":0},"timezone":{"type":"string"}}}}
```

Additional shared screens on web/macOS/iOS: bot.overview (Identity/Job/Memory tabs, activity/upcoming/current task/grants/ideas), activity (workspace aggregate with bot/machine/time filters), upcoming (routines+own reminders), memory.import (source→candidate/provenance/exclusions→review confirm→acknowledged import), preference.changes (diff/actor/scope/source/machine and conflict-safe Undo), bot.reset (scope checklist/exact preview/residual retention/token confirm), connector.setup (assigned machine names-only secrets/grants), and voice.preview (sample without conversation). macOS summon is platform-local window; iOS share extension/web palette remain privacy-bounded surfaces, not new network APIs.

## 11. Configured enterprise identity, policies, integrations, exports and host control

These are **real configurable product contracts**, not N/A placeholders or vendor-specific account linking. Providers/host drivers require operator credentials/permissions as listed below; absent configuration returns capability_unavailable, and the screen reports the exact prerequisite. No fake fallback or scope reduction. Local-account bootstrap retained. All paths below under /v1, including SCIM base `/v1/scim/v2`; only architecture hook and MCP retain outside-v1 paths. Same resource/nonce/ACL errors for product JSON, with SCIM standard exceptions.

| Method/path under /v1 | Request | Response | Query | Required role / ACL | Additional errors |
|---|---|---|---|---|---|
| `GET /auth/oidc/providers` | `undefined` | `{ id: ID; name: string; enabled: boolean; requireSSO: boolean }[]` | `undefined` | Public / verified OIDC flow | unauthenticated, expired, policy_denied, capability_unavailable |
| `POST /auth/oidc/start` | `OIDCStart` | `OIDCFlow` | `undefined` | Public / verified OIDC flow | unauthenticated, expired, policy_denied, capability_unavailable |
| `GET /auth/oidc/callback/:providerId` | `undefined` | `RedirectResponse` | `OAuthCallbackQuery` | Verified OAuth/OIDC state | unauthenticated, expired, upstream_unavailable |
| `POST /auth/oidc/complete` | `OIDCComplete` | `AuthResult \| ReauthResult` | `undefined` | Public / verified OIDC flow | unauthenticated, expired, policy_denied, capability_unavailable |
| `GET /admin/oidc/providers` | `undefined` | `Page<OIDCProvider>` | `PageQuery` | Owner (identity/token) / Admin (governance) | policy_denied, conflict, capability_unavailable |
| `POST /admin/oidc/providers` | `OIDCProviderCreate` | `OIDCProvider` | `undefined` | Owner (identity/token) / Admin (governance) | policy_denied, conflict, capability_unavailable |
| `PATCH /admin/oidc/providers/:id` | `OIDCProviderUpdate` | `OIDCProvider` | `undefined` | Owner (identity/token) / Admin (governance) | policy_denied, conflict, capability_unavailable |
| `DELETE /admin/oidc/providers/:id` | `Update` | `Deleted` | `undefined` | Owner (identity/token) / Admin (governance) | policy_denied, conflict, capability_unavailable |
| `GET /directory/groups` | `undefined` | `Page<DirectoryGroup>` | `PageQuery` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `POST /directory/groups` | `DirectoryGroupCreate` | `DirectoryGroup` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `PATCH /directory/groups/:id` | `DirectoryGroupUpdate` | `DirectoryGroup` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `DELETE /directory/groups/:id` | `Update` | `Deleted` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `GET /directory/groups/:id/policy` | `undefined` | `GroupPolicy` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `PATCH /directory/groups/:id/policy` | `GroupPolicyUpdate` | `GroupPolicy` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `GET /governance` | `undefined` | `Governance` | `undefined` | Owner (identity/token) / Admin (governance) | policy_denied, conflict, capability_unavailable |
| `PATCH /governance` | `GovernanceUpdate` | `Governance` | `undefined` | Owner (identity/token) / Admin (governance) | policy_denied, conflict, capability_unavailable |
| `GET /policies/effective` | `undefined` | `EffectivePolicy` | `{ userId?: ID; botId?: ID }` | Own / Admin target user | policy_denied |
| `GET /network-policies` | `undefined` | `Page<NetworkPolicy>` | `PageQuery` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `POST /network-policies` | `NetworkPolicyCreate` | `NetworkPolicy` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `PATCH /network-policies/:id` | `NetworkPolicyUpdate` | `NetworkPolicy` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `DELETE /network-policies/:id` | `Update` | `Deleted` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `GET /network-policies/:id/applications` | `undefined` | `Page<PolicyApplication>` | `PageQuery` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `POST /network-policies/:id/apply` | `Mutation & { machineIds: ID[] }` | `Page<PolicyApplication>` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `GET /egress-routes` | `undefined` | `Page<EgressRoute>` | `PageQuery` | Machine + effective egress/management grant | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `POST /egress-routes` | `EgressRouteCreate` | `EgressRoute` | `undefined` | Machine + effective egress/management grant | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `PATCH /egress-routes/:id` | `EgressRouteUpdate` | `EgressRoute` | `undefined` | Machine + effective egress/management grant | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `DELETE /egress-routes/:id` | `Update` | `Deleted` | `undefined` | Machine + effective egress/management grant | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `GET /setup-manifests` | `undefined` | `Page<SetupManifest>` | `PageQuery` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `POST /setup-manifests` | `SetupManifestCreate` | `SetupManifest` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `PATCH /setup-manifests/:id` | `SetupManifestUpdate` | `SetupManifest` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `DELETE /setup-manifests/:id` | `Update` | `Deleted` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `POST /setup-manifests/:id/run` | `Mutation & { machineIds: ID[] }` | `Page<SetupRun>` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `GET /setup-runs` | `undefined` | `Page<SetupRun>` | `PageQuery & { manifestId?: ID; machineId?: ID }` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `GET /machines/:id/management` | `undefined` | `HostManagement` | `undefined` | Machine + effective egress/management grant | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `POST /host-operations/preview` | `HostOperationPreview` | `Confirmation` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `POST /host-operations` | `HostOperationCreate` | `HostOperation` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `GET /host-operations` | `undefined` | `Page<HostOperation>` | `PageQuery` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `GET /host-operations/:id` | `undefined` | `HostOperation` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `GET /spend-limits` | `undefined` | `Page<SpendStatus>` | `PageQuery` | Own user/bot/routine / Admin workspace | policy_denied, conflict, upstream_unavailable |
| `POST /spend-limits` | `SpendLimitCreate` | `SpendLimit` | `undefined` | Own user/bot/routine / Admin workspace | policy_denied, conflict, upstream_unavailable |
| `PATCH /spend-limits/:id` | `SpendLimitUpdate` | `SpendLimit` | `undefined` | Own user/bot/routine / Admin workspace | policy_denied, conflict, upstream_unavailable |
| `DELETE /spend-limits/:id` | `Update` | `Deleted` | `undefined` | Own user/bot/routine / Admin workspace | policy_denied, conflict, upstream_unavailable |
| `GET /export-destinations` | `undefined` | `Page<ExportDestination>` | `PageQuery` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `POST /export-destinations` | `ExportDestinationCreate` | `ExportDestination` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `PATCH /export-destinations/:id` | `ExportDestinationUpdate` | `ExportDestination` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `DELETE /export-destinations/:id` | `Update` | `Deleted` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `POST /exports` | `AuditExportCreate` | `ExportRecord` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `GET /exports` | `undefined` | `Page<ExportRecord>` | `PageQuery` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `GET /exports/:id` | `undefined` | `ExportRecord` | `undefined` | Admin + explicit affected resource authority | policy_denied, machine_offline, capability_unavailable, outcome_unknown |
| `POST /channels/setup` | `ChannelSetup` | `ChannelSetupFlow` | `undefined` | Manage bot / Own verified channel identity | policy_denied, capability_unavailable, upstream_unavailable, expired |
| `GET /channels/setup/:id` | `undefined` | `ChannelSetupFlow` | `undefined` | Manage bot / Own verified channel identity | policy_denied, capability_unavailable, upstream_unavailable, expired |
| `GET /channels/oauth/callback` | `undefined` | `ChannelSetupFlow` | `OAuthCallbackQuery` | Verified OAuth/OIDC state | unauthenticated, expired, upstream_unavailable |
| `POST /channels/principal-links` | `ChannelLinkCreate` | `ChannelPrincipalLink` | `undefined` | Manage bot / Own verified channel identity | policy_denied, capability_unavailable, upstream_unavailable, expired |
| `GET /channels/principal-links` | `undefined` | `Page<ChannelPrincipalLink>` | `PageQuery` | Manage bot / Own verified channel identity | policy_denied, capability_unavailable, upstream_unavailable, expired |
| `DELETE /channels/principal-links/:id` | `Update` | `Deleted` | `undefined` | Manage bot / Own verified channel identity | policy_denied, capability_unavailable, upstream_unavailable, expired |
| `POST /email/address/check` | `EmailAddressCheck` | `EmailAddressAvailability` | `undefined` | Own + enabled integration policy | policy_denied, capability_unavailable, upstream_unavailable, rate_limited, conflict |
| `POST /email/address/claim` | `EmailAddressClaim` | `EmailAccount` | `undefined` | Own + enabled integration policy | policy_denied, capability_unavailable, upstream_unavailable, rate_limited, conflict |
| `GET /email/accounts` | `undefined` | `Page<EmailAccount>` | `PageQuery` | Own + enabled integration policy | policy_denied, capability_unavailable, upstream_unavailable, rate_limited, conflict |
| `GET /email/accounts/:id/messages` | `undefined` | `Page<EmailMessage>` | `PageQuery & { query?: string; sender?: string }` | Own + enabled integration policy | policy_denied, capability_unavailable, upstream_unavailable, rate_limited, conflict |
| `GET /email/messages/:id` | `undefined` | `EmailMessage` | `undefined` | Own + enabled integration policy | policy_denied, capability_unavailable, upstream_unavailable, rate_limited, conflict |
| `POST /x/connections` | `XConnect` | `XConnectResult` | `undefined` | Own + enabled integration policy | policy_denied, capability_unavailable, upstream_unavailable, rate_limited, conflict |
| `GET /x/connections` | `undefined` | `Page<XConnection>` | `PageQuery` | Own + enabled integration policy | policy_denied, capability_unavailable, upstream_unavailable, rate_limited, conflict |
| `PATCH /x/connections/:id` | `XConnectionUpdate` | `XConnection` | `undefined` | Own + enabled integration policy | policy_denied, capability_unavailable, upstream_unavailable, rate_limited, conflict |
| `DELETE /x/connections/:id` | `Update` | `Deleted` | `undefined` | Own + enabled integration policy | policy_denied, capability_unavailable, upstream_unavailable, rate_limited, conflict |
| `GET /x/oauth/callback` | `undefined` | `XConnection` | `OAuthCallbackQuery` | Verified OAuth/OIDC state | unauthenticated, expired, upstream_unavailable |
| `POST /integrations/:providerId/events` | `IntegrationWebhook` | `IntegrationIngressReceipt` | `undefined` | Verified provider signature / scoped event token | unauthenticated, conflict, policy_denied, capability_unavailable |
| `POST /integrations/x/mentions` | `XIngress` | `IntegrationIngressReceipt` | `undefined` | Verified provider signature / scoped event token | unauthenticated, conflict, policy_denied, capability_unavailable |
| `GET /integration-tokens` | `undefined` | `Page<IntegrationToken>` | `PageQuery` | Owner (identity/token) / Admin (governance) | policy_denied, conflict, capability_unavailable |
| `POST /integration-tokens` | `IntegrationTokenCreate` | `IntegrationTokenIssued` | `undefined` | Owner (identity/token) / Admin (governance) | policy_denied, conflict, capability_unavailable |
| `DELETE /integration-tokens/:id` | `Update` | `Deleted` | `undefined` | Owner (identity/token) / Admin (governance) | policy_denied, conflict, capability_unavailable |
| `GET /scim/v2/ServiceProviderConfig` | `undefined` | `SCIMServiceProviderConfig` | `undefined` | SCIM integration | SCIMError (standard status), uniqueness, mutability, invalidFilter |
| `GET /scim/v2/ResourceTypes` | `undefined` | `SCIMList<SCIMResourceType>` | `SCIMQuery` | SCIM integration | SCIMError (standard status), uniqueness, mutability, invalidFilter |
| `GET /scim/v2/Schemas` | `undefined` | `SCIMList<SCIMSchema>` | `SCIMQuery` | SCIM integration | SCIMError (standard status), uniqueness, mutability, invalidFilter |
| `GET /scim/v2/Users` | `undefined` | `SCIMList<SCIMUser>` | `SCIMQuery` | SCIM integration | SCIMError (standard status), uniqueness, mutability, invalidFilter |
| `POST /scim/v2/Users` | `SCIMUserInput` | `SCIMUser` | `undefined` | SCIM integration | SCIMError (standard status), uniqueness, mutability, invalidFilter |
| `GET /scim/v2/Users/:id` | `undefined` | `SCIMUser` | `undefined` | SCIM integration | SCIMError (standard status), uniqueness, mutability, invalidFilter |
| `PUT /scim/v2/Users/:id` | `SCIMUserInput` | `SCIMUser` | `undefined` | SCIM integration | SCIMError (standard status), uniqueness, mutability, invalidFilter |
| `PATCH /scim/v2/Users/:id` | `SCIMPatch` | `SCIMUser` | `undefined` | SCIM integration | SCIMError (standard status), uniqueness, mutability, invalidFilter |
| `DELETE /scim/v2/Users/:id` | `undefined` | `undefined` | `undefined` | SCIM integration | SCIMError (standard status), uniqueness, mutability, invalidFilter |
| `GET /scim/v2/Groups` | `undefined` | `SCIMList<SCIMGroup>` | `SCIMQuery` | SCIM integration | SCIMError (standard status), uniqueness, mutability, invalidFilter |
| `POST /scim/v2/Groups` | `SCIMGroupInput` | `SCIMGroup` | `undefined` | SCIM integration | SCIMError (standard status), uniqueness, mutability, invalidFilter |
| `GET /scim/v2/Groups/:id` | `undefined` | `SCIMGroup` | `undefined` | SCIM integration | SCIMError (standard status), uniqueness, mutability, invalidFilter |
| `PUT /scim/v2/Groups/:id` | `SCIMGroupInput` | `SCIMGroup` | `undefined` | SCIM integration | SCIMError (standard status), uniqueness, mutability, invalidFilter |
| `PATCH /scim/v2/Groups/:id` | `SCIMPatch` | `SCIMGroup` | `undefined` | SCIM integration | SCIMError (standard status), uniqueness, mutability, invalidFilter |
| `DELETE /scim/v2/Groups/:id` | `undefined` | `undefined` | `undefined` | SCIM integration | SCIMError (standard status), uniqueness, mutability, invalidFilter |

### Identity, SCIM and directory groups

OIDC provider management Owner-only; public discovery exposes id/name/enabled/requireSSO, never clientSecretRef/issuer management data. Prerequisite: registered confidential client, HTTPS discovery issuer/JWKS/token endpoints pinned to operator-approved origins, backend private secretRef, redirect registered as `<PUBLIC_URL>/v1/auth/oidc/callback/<providerId>`. OIDCStart requires S256 codeChallenge and allowlisted client redirect (same-origin web, registered native `lemonbot://auth/complete`), purpose login or reauth, optional own device. Backend state/nonce/provider PKCE validates exact issuer/audience/signature/exp/nbf/nonce and verified email; no unsigned JWT or arbitrary issuer fetch. Return OIDCFlow (10 min). Callback returns **302** RedirectResponse with allowlisted location plus one-time completionCode+flowId (not session token); complete presents codeVerifier/completionCode, one-use, returns AuthResult for login OR five-minute ReauthResult for reauth. Existing reauth uses current logged-in subject and provider auth_time/prompt=login, never another identity. No auto-binding an existing local account solely by unverified email: owner-authorized verified linking required; stable identity `(issuer,sub)` persisted. On first verified account use existing invite or permitted SCIM-managed identity/group access; do not open anonymous provisioning. RequireSSO blocks local password for managed users, retains explicit operator break-glass owner only. Group claim maps only preconfigured directory external IDs; roles never inferred from arbitrary client claim/admin words. Disabled provider does not silently unlock local login. Account deletion needs password reauth or OIDC-completed reauth. Provider end-session is independently called at logout/deprovision where supported and reported; product token revocation immediate even if external provider unreachable.

SCIM integration token issued once (digest only later), scopes scim.users/scim.groups, Owner creates/revokes; bearer cannot call product chats/admin APIs. Standard Content-Type application/scim+json, RFC 7643/7644 schemas; User id maps product User+Member, userName normalized unique verified identifier, active=false immediately revokes product sessions/push/WS/pending gates/future routines, without deleting host files. DELETE user deprovisions membership, not private content expose; cannot deprovision final owner. Groups map DirectoryGroup, not chat groups. Groups member list references existing SCIM Users; SCIM operations never grant Owner. SCIM PUT full replacement; PATCH Operations supported paths userName, displayName, name, emails, active, externalId and Groups displayName/externalId/members/add/remove/value filter; unsupported path returns SCIMError scimType invalidPath/mutability, never silently ignored. Last-modified/created are RFC3339 UTC strings (SCIM exception to *AtMs), meta.version strong ETag, If-Match required on existing update/delete, 412 stale, GET 200/POST 201/update 200/delete 204 no body, SCIMError JSON schema on failures (401/403/404/409 uniqueness/400 invalidFilter/413). SCIM has no product clientNonce: standard externalId uniqueness and provider delivery id/header request correlation fence creates; repeated same externalId compatible create returns existing 200, conflicting body 409; no arbitrary batch endpoint (`bulk.supported:false`). startIndex one-based default1, count default50/max200, filter subset exact `userName eq "…"`, `externalId eq "…"`, `displayName eq "…"`, `active eq true|false`, optional `and`; invalid unsupported filters 400. attributes/excludedAttributes fixed known fields, ACL and schema fields retained. ServiceProviderConfig/ResourceTypes/Schemas are actual discovery responses, not fabricated advanced feature promises.

Directory local create/update Admin, SCIM/OIDC-managed memberships cannot be overwritten via local PATCH except explicitly configured owner override; source provenance visible. GroupPolicy has product access/default Bots/capability ceilings/required rules/network references. EffectivePolicy is explainable actual composition: product access is workspace enabled AND enabled membership AND all/selected-group grant; ordinary eligible-group capabilities widen to most permissive bounded by locked workspace hard ceiling; personal choice may tighten; required ask_first wins conflicts, enforced reviewer lock exception only if admin group policy permits it. Default bots union, required bot cannot be hidden by collaborators. Network group policies replace team only if workspace lockNetworkForGroups false; for multiple applicable group policies use intersection (most restrictive), otherwise locked workspace. Allowlist matching domains exact or explicit leading `*.` suffix only (no substring), CIDR canonical IPv4/IPv6+ports/protocol, required runtime destinations explicitly operator-owned and displayed. Source-service/OS access still ceilings. Egress/sudo apply Governance/GroupPolicy with explanation and registered host enforcement; product rules are not shell sandbox claims.

### Applied network, egress, setup and owned-host recovery

Prerequisite: operator HostDriverConfig for selected machine, inspected executable commands/service/container control on destination, node.shell PTY and allowed roots; credentials scoped local host, no frontend-supplied shell scripts/commands for management. HostManagement reports configured tested actions/provider/environmentRoot/backups/network/egress/setup support; unconfigured capabilities false and mutation 503. Driver action launches via trusted node shell immutable command manifest with structured operation ID/target config on stdin, never arbitrary user argv from REST. Exit and verified output settle durable result, loss of acknowledgment outcome_unknown; reconnect probes exact operation ID, no redispatch. For network apply, driver installs domain/IP/port rules with runtime allowlist and returns actual applied revision; admission prevents bot runs requiring enforced network while pending/failed/unsupported, never says “applied” on queue receipt. desired/applied/offline/error visible per machine, running target retries reconciliation (not mutation) within ~1 min; sleeping hosts apply before admission on return. Backend provider fetches also obey operator origin/destination allowlist, not just host firewall. MCP deny separate from website network policy.

EgressRoute requires explicit owner/admin+machine grants on source and throughMachineId plus registered host proxy/tunnel driver. Connect using authenticated/encrypted machine route, no operator tokens or unauthenticated exposed SOCKS endpoint. Actual connecting/active/error observed, route applies new connections; governance disabled stops active route ≤5 min with driver acknowledgment, stores rememberedPreference and locks controls. Reallow may restore only previously explicit choice on still-authorized machines, never a new trust grant. Different bot destination never silently inherits route; no screen/Cloud Agent network assumption.

SetupManifest Admin+Machine only, scoped workspace/group/machine set, sequential stable entry IDs with setup/check scripts stored as reviewed operator config. max30 min/entry, canonical safe defaults; check exit0 skips, setup then recheck, failure is redacted SetupRun not false success, idempotent replay exact manifest+machine revision, new requested run explicit. Use real host driver and node shell, not fake stdout. Inject only named encrypted destination secrets during check/setup child process, wipe transient env/buffers, secret scrub output before summary/audit. Multiple workspace/team manifests on shared host receive no cross-tenant secrets; config refuses inconsistent ownership. No secrets in plain script argv/public JSON. Destination-local provider auth unchanged. Scheduled refresh/start/recover installs use canonical Lemon cron host provisioning driver or operator service, no second agent cron engine.

Host operations preview exact ≤1000 authorized machines/actions/environment roots/backup age/candidate revisions and retained vs lost scope. ConfirmName is generated preview phrase `ACTION N machines` for bulk (single machine exact name), token binds exact sorted IDs/action/driver configuration+revisions, max5 min; one active operation/workspace. Accepted POST returns 202 HostOperation; response loss same nonce returns same ID, no-start conflict changes nothing. Background server records per-machine queued/running/succeeded/skipped/failed/unknown; closing dialog/client does not abort. Existing no-op/unsupported target skipped **only with explicit reason**, not treated as success; no driver returns capability_unavailable before operation if none supports action. Driver must pause active runs at verified safe point or fail preserving machine; no forced stop disguised as update. Update/recover/restart_worker use actual existing host service, preserve disk/identity; newest unsaved data/backups warning when relevant. recreate_environment/delete_environment apply **only configured isolated Lemon-owned environmentRoot**, never user whole host/home/SSH/files. delete_environment additionally lists every root/filesystem scope, requires backup/residual data disclosure and exact confirmation. stop_worker is execution stop, not access revocation; detach is separately nodes.revoke. Inactive policy default off, afterDays default30, only verified idle/sleeping hosts with explicit suspend/stop support, never awake/working host or host file deletion; disk retained, operator restart/authorized wake resumes. Low disk actual HostInfo prompts cleanup approval, no conversation deletion or reset because sidebar missing.

### Self-hosted usage, limits and audit exports

Spend limits are real per workspace/user/bot/routine and optional configured provider account, day/week/month UTC windows, finite nonnegative USD, warningPercent 1–99. Required workspace ceiling plus matching narrower limits enforced before **new** run/routine/test/handoff/group target; no secret fallback to owner's budget. Actual Lemon usage.cost attribution and configured provider spend reconciliation drive SpendStatus; unknown price/incomplete measurement state unknown and refuses new work under enforced limit (policy_denied with explanation), never pretends zero spend. Running admitted work may finish above ceiling, no false mid-run hard-dollar cap. No selling Lemon subscription plans/entitlement merging/refunds, external provider billing stays provider-managed. Reset instant provided, routine/group cost visible; raising own limit cannot bypass admin ceiling. Bare no limits retains truthful usage, not infinite paid grant fiction.

Audit/action/usage and conversation content are separate streams, metadata retained policy default90 days; audit includes actual identity/group/policy/provider/host lifecycle actor/result/request IDs. Content export default false, Governance.contentExportEnabled Admin plus export requester content ACL/participant opt-in, selected conversationIds explicit; owner cannot export another user's private DM by admin role alone. Known secret shapes/values scrubbed, residual personal-data risk explained, no automatic training/telemetry. ExportDestination requires operator-approved HTTPS collector URL/public origin or explicitly allowed private deployment endpoint, pinned origin/no redirects, secretRef backend encrypted env/file configuration (not Bot secrets), protocol otlp_http/ndjson_webhook, streams enabled; actor authorizes content per stream. Persist delivery outbox+cursor, retries exact record with stable idempotency header, no future-backfill when enabling stream (starts current watermark); turning off prevents new events. Explicit historical exports selected range produce ExportRecord async and ACL-bound attachment on completion, not automatic disabled history replay. Collector acknowledgment does not prove analysis performed. GET export status/download actual blob; failed provider state/error not fake file. OTLP resource product `lemon_bot`, structured metadata (actor/bot/run/machine/outcome/duration), never raw command/credential/transcript unless explicitly opted content stream. Provider unavailable remains queued/failed accurately.

### Channels, X mention integration, email and event providers

Prerequisite providers are explicitly operator-configured with OAuth client/signing/provisioning/provider-account permission, redirect allowlist, actual adapter capabilities. ChannelSetup starts real authorize/install flow; status includes awaiting_admin/denied/failed rather than assuming installation. Slack supports actual configured per-Bot app provider: published Bot and owner/manager install authority, workspace admin approval, welcome/invite/remove via Slack APIs, callbacks signature/state-bound. Verified ChannelPrincipalLink external userId→enabled product User through one-use code in own DM/oauth; cannot accept caller's arbitrary user mapping. Unlinked users get private linking instructions/refusal and no owner run/spend; configured workflow/app principal can explicitly use owner authority only if operator grants fixed application identity. DM every mapped message, channel top-level explicit mention starts participation, subsequent thread replies wake same private/shared context; event listener routines separate plugin posts/app mentions. Removal calls actual provider uninstall/revoke and disables binding, preserves product Bot; failure displays provider-admin cleanup required. Discord/Telegram/WhatsApp/email retain real configured Lemon adapter account capabilities.

GitHub/Linear/Sentry/PagerDuty IntegrationWebhook endpoint verifies provider raw-body signature/timestamp/replay window with operator secret, exact registered eventNames (GET event-sources), source deliveryId dedupe and filter schema. Slack/email events likewise normalized from verified adapter; old events no backfill, broad any-message requires explicit noisy-listener consent. REST path `/integrations/:providerId/events` never lets payload choose arbitrary user/profile/machine; target fixed configured routine/binding and principal, unsupported event rejected/ignored with exact reason, nonce/receipt persisted. Incoming attachments checked/copied via authorized source allowlist, no arbitrary credentialed URL fetching. Integration-scoped bearer permitted only operator delivery bridge, never public clients.

X OAuth connection actual user and selected owned mainBotId, OAuth scopes explicit public mention read/post-confirmation vs private accounts/tools, provider return state/verifier exact. `/integrations/x/mentions` verifies actual registered X webhook CRC/signature via configured provider gateway or trusted bearer bridge, deliveryId dedupe, mapped external account, configured public handle in user's own explicit mention (not incidental thread mention), surrounding replied/quoted contextual posts/photos as untrusted input. Actual provider media/region/moderation/usage rules evaluated/configured; disallowed media, disabled account/policy/exhausted limit yields ignored with reason and no run. Public short confirmation posted only after actual accepted receipt; result stays selected private Bot conversation. Missing link/no own Bot replies configured sign-in/setup text, not false accepted. Provider API failures or uncertain confirmation/send reconcile receipts; no fabricated public handle confirmation. Protected X features still require explicitly granted private MCP scopes. No automatic social Accounts Center linking or blanket read-all credentials.

Email provider supports address provisioning plus real authenticated incoming and outward SMTP/provider API. Check validates ≤64 lower-case letters/digits/dot/hyphen/underscore, letter/digit ends, reserved configured names, one active account-owned claimed address, throttling; availability reflects actual provisioning provider. Claim requires pending approved Approval category permissions exact localPart/provider/principal, verifies still available, stable nonce, creates EmailAccount only actual successful provider claim. immutableAddress true reflects configured provider policy; refuse rename/reissue and retire address on account deletion where provider supports immutable namespace, otherwise clearly provider-defined lifecycle. No pretend mail.grokbot.com address. Mail read/search is genuine configured provider/account query; EmailMessage auth/scan status, failed spam/virus retains metadata text null/no unsafe attachment; eventual indexing warning actual provider, no fake product new-mail notification guarantee. Email routines default accept authenticated/scanned passed only, exact sender/domain wildcards (no subject-filter claim); email alone does not wake run unless matching explicitly configured trigger. In/out attachment ≤10/10 MiB each/25 MiB total, 50 total To/Cc/Bcc, executable block, provider unsubscribes/bounces/complaints suppress unauthorized repeat send and report skipped recipient. First-contact/newsletter single recipient/one-click unsubscribe when relevant provider supports, else fail capability_unavailable rather than unsafe send. All outward Bot email including routines/replies requires explicit reviewed DraftSend exact content/from account. Provider-only capability email disable stops tools/triggers, existing inbound retention separately reported; account deletion retires/removes mailbox through provider then shows uncertain cleanup if no ack. Secrets/provider authorization not model input.

New durable events (full resource payload, own/admin-visible by same resource ACL): directory_group.upserted DirectoryGroup, directory_group.deleted Deleted, group_policy.upserted GroupPolicy, governance.updated Governance, network_policy.upserted NetworkPolicy, network_policy.deleted Deleted, policy_application.upserted PolicyApplication, egress.upserted EgressRoute, setup_manifest.upserted SetupManifest, setup_run.upserted SetupRun, host_operation.upserted HostOperation, spend_limit.upserted SpendLimit, export.upserted ExportRecord, channel_setup.upserted ChannelSetupFlow, email_account.upserted EmailAccount, x_connection.upserted XConnection. OIDC/SCIM secrets, provider mail content/addresses and scripts are never broad workspace fanout. Other integration state/deletions refreshed from affected owning GET after revocation; no catch-all arbitrary event type.

All clients add settings.identity (OIDC providers/SSO requirement/SCIM token/discovery/group mappings), settings.directory (groups/access/default Bots), settings.network (effective policy/rules/applied host revisions/egress), settings.setup (reviewed manifests/redacted runs), settings.exports (destinations/streams/authorized historical export), settings.usage.limit (own/admin ceilings), integrations.email (provision/read/search/account/draft/trigger), integrations.x (explicit OAuth/main bot/handle/mention state), integrations.channels (app install/admin/link/threads/removal) and machines.operations (preview/bulk server progress/actual host driver support). Existing account/workspace/policies/usage/Machine screens deep-link these panes; iOS management available under role, secrets masked. No fake unconfigured forms claiming success.

Operator configuration is a private JSON file containing typed OperatorConfiguration (§README) with reviewed host command manifests, provider origins, signing/OAuth credential **references**, callback/redirect and runtime destination allowlists. Local account setup works without enterprise providers; OIDC/SCIM/groups/spend limits/audit models implemented independently, provider work requires real credentials. There is no internal-vendor endpoint reuse, quota bypass, attestation/security marketing or ambient capture. External prerequisites are surfaced precisely through capabilities/state/error, not used to silently omit any of the 101+16 cases.

### Completion of discovery and provisioning catalog

| Method/path under /v1 | Request | Response | Query | Required role / ACL | Additional errors |
|---|---|---|---|---|---|
| POST /email/address/approval | EmailAddressProposal | Approval | undefined | Own Bot + enabled email policy | policy_denied, capability_unavailable, conflict, rate_limited |
| GET /scim/v2/ResourceTypes/:id | undefined | SCIMResourceType | undefined | SCIM integration | SCIMError notFound/invalidValue |
| GET /scim/v2/Schemas/:id | undefined | SCIMSchema | undefined | SCIM integration | SCIMError notFound/invalidValue |

Email address flow: Check availability → POST approval creates exact permissions proposal for that provider/localPart/principal → target explicitly resolves approve_once → Claim verifies approved exact request. Deny/expiry never provisions; same approved ID cannot claim a different address. Direct GUI and chat-assisted requests use same actual provider claim path.

GroupPolicy.reviewExempt default false: only Admin can set, specifically removes Governance.requireReview for that eligible group; it does **not** override a still-required ask_first rule, explicit DraftSend, connector-account consent, OS grant or network hard lock. Multiple eligible exempt groups widen reviewer exemption as ordinary capability, required action rules still dominate. Default group controls productAccess true, defaultBotIds empty, capabilityModes empty, requiredRuleIds empty, localExecutionCeiling ask, allowEgress false, allowSudo false, networkPolicyId null. Governance defaults groupAccess all/allowedDirectoryGroupIds empty, sudo/egress false until reviewed host setup, lockNetworkForGroups true, requireReview true, adapters empty until enabled, X/email false, content export false, inactive disabled/30 days/stop_worker. Default spend limit absent, configured finite ceiling enforce known prices, no cap invented from vendor weekly grants.

MachineInvite.enrollment is exact invited/waiting_for_join/connecting/verifying/online/expired/failed/revoked; status pending/joined/expired/revoked remains credential lifecycle, lastError scrubbed. UI may transition connecting/verifying only on real worker/controller facts. Online requires actual enrolled durable node+accepted generation, not command copy. Milestone machine_attached tied to Bot's placement on an actually verified online machine, not a prematurely created pending Bot.

The private config file shape is OperatorConfiguration, version 1. Minimal local-only configuration (optional integrations unconfigured, not fake):

```json
{"version":1,"trustedFrontendOrigins":[],"oauthRedirectUris":["lemonbot://auth/complete"],"serverSecrets":{},"channelProviders":[],"emailProviders":[],"eventProviders":[],"hostDrivers":[],"xProvider":null,"exportAllowedOrigins":[],"requiredRuntimeDestinations":[],"breakGlassOwnerUserId":null}
```

Populate real reviewed provider/host entries using exported OAuthProviderConfig, ChannelProviderConfig, EmailProviderConfig, EventProviderConfig, HostDriverConfig and ServerSecretSource. ServerSecretSource references exactly one existing environment variable or owner-readable private file; never write actual credential strings into exported frontend config. OAuth/provider endpoints are HTTPS and operator-origin-pinned, optional private collector origins explicit. All optional credential/provider variable names in README are normative implementation inputs; absence advertises false capability or actual unavailable integration state. OIDCProvider management references serverSecrets keys; setup secrets use destination store, unrelated server OAuth keys never sent to a Bot machine. X OAuth callback registered PUBLIC_URL/v1/x/oauth/callback; Slack/channel callback PUBLIC_URL/v1/channels/oauth/callback; account MCP OAuth callback PUBLIC_URL/v1/connectors/oauth/callback. EventProvider maxAgeMs default300000/max600000, duplicate verified deliveryId fenced; operator ingress providerId lookup fixed (payload cannot invent provider/target). Host driver argv/probe commands are reviewed immutable local executable manifests, no client-controlled shell interpolation; structured stdin carries scoped operation ID/config, credential env limited to intended child process. A configured driver must implement actual apply/probe/stop and signed authorization/operation correlation, not a no-op "success" program.

Product JSON timestamp/error/nonce conventions explicitly exclude standard SCIM bodies, SCIMError/ETag/If-Match and 204 deletes, and OIDC 302 redirect wire response. Every other response remains typed JSON/BinaryBody as listed. /v1/scim/v2 schemas URNs: User urn:ietf:params:scim:schemas:core:2.0:User, Group core:2.0:Group, PatchOp urn:ietf:params:scim:api:messages:2.0:PatchOp, ListResponse api:messages:2.0:ListResponse, Error api:messages:2.0:Error. SCIM public discovery still scoped integration bearer; no anonymous directory. OIDC login provider summary is intentionally anonymous read so sign-in UI can pick the real registered IdP, never display management secrets.

### Own account identity linking and participant content consent

| Method/path under /v1 | Request | Response | Query | Required role / ACL | Additional errors |
|---|---|---|---|---|---|
| GET /auth/identities | undefined | Page<IdentityLink> | PageQuery | Own | unauthenticated |
| POST /auth/oidc/link | OIDCLinkRequest | IdentityLink | undefined | Own + one-use reauth | expired, conflict, policy_denied, upstream_unavailable |
| DELETE /auth/identities/:id | IdentityUnlink | Deleted | undefined | Own + one-use reauth | expired, conflict, policy_denied |
| GET /conversations/:id/export-consent | undefined | ContentExportConsent | undefined | Own participant | forbidden, not_found |
| PUT /conversations/:id/export-consent | ContentExportConsentUpdate | ContentExportConsent | undefined | Own participant | forbidden, revision_conflict |

IdentityLink is user's verified provider issuer+subject, no credentials/token. Linking uses OIDCStart purpose link authenticated as account owner, same callback/PKCE verification, then /auth/oidc/link with reauthToken and one-time completionCode/verifier. /auth/oidc/complete refuses link-purpose flows; never silently merges accounts by email. Prevent linking subject already bound to another User; require same verified email or explicitly owner-reviewed preprovisioned SCIM mapping. Unlink needs current reauth and cannot remove final login method or required SSO authority; revokes associated provider sessions immediately, external end-session separately reported. Login summaries remain read-only/secret-free.

ContentExportConsent keyed `(conversationId,userId)` defaults enabled false, GET seeds own revision-1 row, PUT exact revision/nonce. Global contentExportEnabled and every current human participant's explicit enabled consent required before exporting a shared conversation; private DM requires only its human participant. Recheck at queued delivery/attachment download, not only export creation. Revocation stops new content packets/exports for that conversation and invalidates undelivered queued content; cannot erase prior acknowledged external collector copies, explain residual scope. Consent is private own GET/PUT state; no broad workspace consent payload fanout. Owner/admin cannot set another participant's consent. Settings.exports and conversation details expose the toggle/actual blocked reason.

EmailAddressProposal adds required botId so GUI cannot silently invent Bot attribution for a mailbox claim; Bot owned by caller and on actual chosen machine. No Bot yet requires creation first. Availability check does not need botId; approval and claim share exact user/provider/localPart, approved gate expires as normal, claim receipt preserves actual provider outcome.
