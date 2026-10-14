# Lemon Bot provider and host configuration

This is the operator reference for the product backend adapters. Product REST types and permissions remain canonical in [contracts/api.md](contracts/api.md) and [contracts/protocol.ts](contracts/protocol.ts). Provider configuration is private; clients receive only the safe provider catalog, capabilities and resource state. The Lemon operator token is never a product credential.

## Configuration and credential custody

Set `LEMON_BOT_CONFIG_FILE` to an owner-readable JSON file, or use `DATA_DIR/config.json`. Configuration version is 1. A missing file is local-only operation: optional providers are absent, not simulated. Unknown configuration properties, invalid credential references, duplicate provider identifiers and OAuth destinations outside pinned origins fail validation. A minimal file is:

```json
{"version":1}
```

The canonical defaults are no providers, no host drivers, no public export destinations and `oauthRedirectUris:["lemonbot://auth/complete"]`. Every canonical field in `OperatorConfiguration` is supported. Configure `trustedFrontendOrigins` explicitly for cross-origin clients; do not put the control-plane URL in this list.

`serverSecrets` maps names to **references**, not credential values:

```json
{"serverSecrets":{"slack-oauth":{"kind":"env","name":"SLACK_CLIENT_SECRET"},"collector":{"kind":"file","path":"/private/lemon-bot/collector-token"}}}
```

Files must exist and be private to the service user; environment variables must be available in the backend service environment. Provider operations return the exact missing reference/permission prerequisite, without returning secret values or raw provider exceptions. Do not commit config with sensitive URLs, scripts or identifiers.

Bot MCP header credentials are different: destination node encrypted secrets only. The backend stores header-to-secret **names**, preserving `${LEMON_SECRET:NAME}` references in profile/invocation MCP configuration. OAuth exchanges write the obtained credential into that bot's assigned destination node's encrypted store. No model-visible plaintext, no automatic migration of credentials on moving or copying a bot, and no host isolation claim for personas sharing an OS user.

## OIDC, SCIM and directory governance

Before any provider CRUD, discovery, JWKS, authorization, token exchange or logout, the **server operator** must configure canonical `oidcAllowedOrigins` (exact HTTPS origins) and `oidcClientApprovals` (`{origin,clientId,clientSecretRef}`). Approval defaults to empty; product Owner is not server-operator authority and cannot send a configured secret to an arbitrary issuer. Approve every actual metadata endpoint origin with the same exact client/ref association, including split-origin providers. Redirects are refused; addresses must be public unless the exact origin is explicitly in `oidcApprovedPrivateOrigins`, a subset of allowed origins. Local password authentication remains independent.

Create OIDC providers as product Owner using a confidential registered client, issuer URL, client ID and an existing approved backend `clientSecretRef`. Register the exact callback `<PUBLIC_URL>/v1/auth/oidc/callback/<providerId>`. Scopes must include `openid` and verified email; allowed email domains remain explicit. A minimal operator approval is:

```json
{"oidcAllowedOrigins":["https://idp.example"],"oidcClientApprovals":[{"origin":"https://idp.example","clientId":"registered-client-id","clientSecretRef":"oidc-secret"}],"serverSecrets":{"oidc-secret":{"kind":"env","name":"OIDC_CLIENT_SECRET"}}}
```

Login/reauth/link require S256 client PKCE, a ten-minute server state/nonce, signature/JWKS verification, exact issuer/audience/expiry and a one-time completion code. A callback is a 302 redirect, not a product bearer in a URL. Subject linking never silently merges accounts by matching email. Break-glass local owner authority is configured by `breakGlassOwnerUserId`; linking/unlinking needs current reauth and cannot remove a required or final login method.

Private reviewed identity mappings are supported:

```json
{"oidcGroupMappings":[{"providerId":"oidc_provider_id","externalId":"engineering","directoryGroupId":"directory_group_id","name":"Engineering"}],"oidcSubjectMappings":[{"providerId":"oidc_provider_id","subject":"verified-idp-subject","userId":"existing_scim_user_id"}]}
```

An absent named mapped group can be provisioned with source `oidc`. Existing targets must already be OIDC-managed with the exact external identifier; mappings never overwrite SCIM/local membership. SCIM `/v1/scim/v2` uses integration bearer scopes `scim.users` and/or `scim.groups`, RFC schemas, `application/scim+json`, ETag/If-Match and standard 204 deletes. Issue/revoke its digest-only integration token as Owner. Product sessions and integration tokens are not interchangeable. Deactivation/deletion immediately removes execution/session/push/gate/routine authority, protects the last Owner and preserves host files. Provider end-session is a separate observed operation, not proof an external IdP erased all sessions.

Account deletion snapshots original external targets before effects. Owner account teardown status observes exact mailbox-retirement, access/refresh-token revocation and OIDC RP-logout receipts, even after local user data is removed; local deletion is not held hostage by provider failure. A missing configured revocation/logout capability is `failed` with its prerequisite, not `not_required`. A dispatch with a lost acknowledgment remains `outcome_unknown` and is never resent by a status read. OAuth exchanges have durable pre-dispatch markers; a late grant after the deletion fence is cleaned up once under that original teardown, never installed or resumed. OIDC RP logout requires a matching approved post-logout redirect/state, not an arbitrary HTTP 200. It does not claim universal deletion of an external provider's sessions.

Managed-directory local edits are denied by default. Private `managedDirectoryOwnerOverride:true` permits only the current Owner to make an explicitly audited override while preserving source provenance; subsequent IdP synchronization may replace that override. `audit_export` integration tokens with exact `audit_export` scope can consume only metadata `GET /v1/audit`, not Admin/chat/content/export/download/WebSocket authority.

Governance defaults: group access `all`, no sudo/egress, network hard lock on, review required, no channel/email/X/content-export enablement, and inactive host management off (30-day default). Eligible groups widen ordinary grants; personal restrictions and required ask-first rules tighten them. Workspace execution ceiling and network locks remain ceilings. Group network replacements intersect when unlocked. Published default Team Bots do not confer management or another member's private-chat authority.

Local, signed OIDC and SCIM directory changes reconcile native authority before acknowledging the mutation, including desired changes committed before a later authentication/provider error. Membership changes fence only added/removed users; a group-policy revision fences every affected member, not unrelated users or label-only edits. Global governance changes install the shared floor; caller-specific restrictions never overwrite a Team Bot with its owner's personal policy. Unknown terminal/profile acknowledgments retain admission fences rather than resume stale authority.

## MCP connector providers

`connectorProviders` is optional canonical private configuration:

```json
{"connectorProviders":[{"id":"crm","origins":["https://mcp.example.com"],"oauth":{"id":"crm-oauth","clientId":"registered-client","clientSecretRef":"crm-oauth-secret","authorizeUrl":"https://auth.example.com/authorize","tokenUrl":"https://auth.example.com/token","scopes":["tools.read"],"redirectUris":["https://bot.example.com/v1/connectors/oauth/callback"],"allowedOrigins":["https://auth.example.com"]},"sharedServiceAccount":false}],"approvedPrivateMcpOrigins":[]}
```

The backend must reach its approved OAuth endpoints; the execution node must reach the approved HTTPS streamable MCP origin. Private MCP origins require explicit `approvedPrivateMcpOrigins`, not a caller-selected local address. Add/setup does not imply authentication: only successful destination `node.mcp.discover` can report connected. Per-tool enabled controls are enforced in destination invocation config. Personal accounts on Team Bots require an exact account-owner/user/bot/conversation grant; allow-once binds the particular operation and cannot become a static owner credential. Remembered grants expire or revoke. A shared account is usable only when the operator deliberately declared a service account and authorized that shared connector.

OAuth provider configuration additionally supports `revocationUrl`, `introspectionUrl` and `clientAuthentication:"basic"|"body"`. All URLs must belong to the configured exact `allowedOrigins`; state uses S256 and a ten-minute one-time expiry. Abandoned grants retain encrypted token evidence. Cleanup requires the **original** token issuer/client/secret-ref association, may add a revoke/introspect endpoint to that association, revokes access and refresh independently via RFC 7009, and observes ambiguous outcomes with RFC 7662 `active:false`; an arbitrary 200 error payload is not proof of revocation. No status read retries a POST.

## Channels, email, event sources and X

Provider IDs must be globally unique across channel/email/event ingress families. All targets, credential references, API origins and routing principals come from operator configuration, never incoming text. Provider bodies are bounded, parsed and marked untrusted before model submission. Every delivery is signature-verified before durable deduplication/routing; duplicate IDs with changed bytes are rejected, expired events are ignored, and enabling a listener never backfills old activity.

Canonical `channelProviders` entries contain `{id,adapter,apiBaseUrl,signingSecretRef,accountSecretRef?,oauth?,capabilities}`. Slack requires a confidential app, bot scopes `chat:write`, `im:write`, `users:read`, `conversations` access appropriate to configured channels, and file-upload scope if delivering attachments. Each published Team Bot has its own actual app installation; a workspace administrator must install it and actual `auth.test`/`users.info` identity checks bind app, team and bot. Set the Event Subscription URL to `<PUBLIC_URL>/v1/integrations/slack/events`; native requests use Slack `v0` HMAC over exact body/timestamp with a five-minute freshness window. User identity linking proves an authenticated external sender received the one-time code; it is not a client-supplied Slack user ID. A principal link and fixed configured binding preserve initiating user/thread on work and handoff return.

Non-Slack adapters use a real configured account gateway at `apiBaseUrl`:

| Provider operation | Required request/result |
| --- | --- |
| `POST accounts/verify` | `{accountId,target,botId}` → `{accountId,authenticated:true,targetAllowed:true}` |
| `POST bindings`; `PATCH/DELETE bindings/<product binding ID>` | Register/change/remove the **actual** adapter account with fixed target and operation idempotency key |
| `POST messages` | `{accountId,target,thread,text,attachments:[{filename,mime,dataBase64}],idempotencyKey}` → actual delivery `{accepted:true,messageId}` |
| `GET messages/status/<operationId>` | `{state:"pending"|"sent"|"rejected",messageId:string|null}` for read-only reconciliation |
| `POST identity-links`; `GET identity-links/<flowId>` | Register `{flowId,accountId,linkCode,expiresAtMs}`, then provider-proven `{verified,externalUserId,externalDisplayName}` |

Gateway ingress `<PUBLIC_URL>/v1/integrations/<providerId>/events` uses `x-lemon-timestamp` (Unix milliseconds) and `x-lemon-signature:sha256=<HMAC-SHA256(secret,timestamp+"."+exactRawBody)>`, or a scoped integration bearer, never a human session. Channel envelope is `{deliveryId,event:"message"|"mention",payload:{channelBindingId,externalUserId?,externalAppId?,externalThreadId,text,direct,timestampMs}}`. Explicit `channelApplicationPrincipals:[{providerId,channelBindingId,externalAppId,userId}]` may authorize fixed app/workflow identities; unlinked humans never fall back to the app owner. Slack cleanup uses real `auth.revoke`/`apps.uninstall`; lost outcomes use token status or configured `GET oauth/cleanup/<operationId>` → `{state:"pending"|"revoked"|"failed",resourceId,scope:"grant"}`. Orphaned access and refresh grants remain observed until confirmed.

Canonical `emailProviders` entries contain `{id,domain,provisioningBaseUrl,provisioningSecretRef,smtp,imap,immutableAddresses,reservedLocalParts,supportsUnsubscribe}`. The configured gateway must provision/query/send through the **actual** mailbox provider using its private SMTP/IMAP/provider account; a generic acknowledgment service is not sufficient. Addresses are one-per-account, reserved-name checked, and claimed only after a fixed user/provider/name permissions approval. Required gateway operations:

| Provider operation | Required result |
| --- | --- |
| `GET addresses/availability?localPart=` | `{address,available,reason:string|null}` |
| `POST mailboxes` `{address,localPart,ownerId,idempotencyKey}` | `{address,provisioned:true,immutable}` after real provisioning |
| `GET mailboxes/<address>/messages?query=&sender=&limit=200` | `{messages:ProviderMail[],indexingDelayed}`; `GET .../messages/<provider ID>` returns one `ProviderMail` |
| `POST .../send-policy` `{recipients,subject,body}` | `{firstContact,newsletter,skipped:[{recipient,reason:"unsubscribe"|"bounce"|"complaint"}],unsubscribeUrl:HTTPS|null}` |
| `POST .../messages/send` | Frozen reviewed draft `{idempotencyKey,from,to,cc,bcc,subject,text,attachments,unsubscribe:{url,oneClick:true}|null}` → actual provider acceptance `{accepted:true,messageId,skipped}` |
| `POST .../retire` | `{idempotencyKey,immutableNamespace}` → `{retired:true,address}` |
| `GET .../retirement/<operationId>` | `{state:"pending"|"retired"|"failed",address}` exact original target; no second retire dispatch |

`ProviderMail` is `{id,from,to,subject,receivedAtMs,authentication:"passed"|"failed"|"unknown",scan:"passed"|"spam"|"virus"|"pending",text:string|null,attachments:[{filename,mime,dataBase64}],skippedAttachmentNames:string[]}`. Unsafe mail preserves scan metadata, not body/files. Executable names/MIME/signatures are denied. Files are bounded to ten MiB each/twenty-five MiB total/ten files; To/Cc/Bcc total at most fifty. First-contact/newsletter sends require one recipient and genuine one-click unsubscribe (`List-Unsubscribe` and `List-Unsubscribe-Post` built by gateway). Recipient suppression is persisted/audited. Every send is an explicitly approved immutable owner draft, not a model auto-send. Incoming events are signed `{providerId,deliveryId,event:"email_received"|"unsubscribe"|"bounce"|"complaint",address,timestampMs,message?,recipient?}` at `/v1/integrations/email/events` or the configured provider route. Only an explicit own routine sender filter wakes work; suppression is processed independently of enabling work.

Canonical `eventProviders` contain `{id,source,signingSecretRef,eventNames,routineIds,principalUserId,maxAgeMs}`. GitHub uses `x-hub-signature-256`, Linear `linear-signature` plus signed `webhookTimestamp`, Sentry `sentry-hook-signature` plus signed event time, and PagerDuty `x-pagerduty-signature` v1 plus signed `event.occurred_at`. GitHub must have a signed body timestamp (`created_at`, issue/PR update, repository push); timestamp-less deliveries need the configured timestamp-signing bridge because unsigned headers cannot prove freshness. Each configured event/routine target is checked exactly; no incoming routine ID, credential or arbitrary task authority is accepted.

Canonical `xProvider` contains `{oauth,apiBaseUrl,signingSecretRef,publicHandle,deniedCountries,allowedMedia}` plus private `xPublicAccountSecretRef`, naming a distinct configured public Bot credential. `apiBaseUrl` must provide the authenticated real X `/2` proxy **and** actual moderation/media bridge; direct `api.x.com` alone does not provide these prerequisites. User linking has only `tweet.read`, `users.read`, optional `offline.access`; protected MCP tools have separate consent. `GET 2/users/me` proves both user account and configured public handle, and main Bot must be the user's own personal Bot. Proxy operations cover real tweet/context lookup/post/timeline, `POST moderation/check` → `{allowed,reason,country,usageAllowed,mediaAllowed}`, verified post-owned `GET media/<media_key>?postId=` → `{mediaKey,filename,mime,dataBase64}`, `POST 2/oauth2/revoke` with Basic/form → `{revoked:true}`, and read-only `GET revocations/<operationId>` → `{state:"pending"|"revoked"|"failed",tokenType}`. Require both access and refresh retirement when present.

Native X CRC and `x-twitter-webhooks-signature` are supported; normalized bridge mentions are verified against actual provider account/post/context, not caller-supplied media IDs or usernames. Only own explicit mentions, allowed region/usage/media, effective access and spend admission dispatch work. Replies/results stay in the private main Bot; the public Bot posts a short accepted acknowledgment **only after** actual runtime acceptance. Unknown public delivery is reconciled against the public timeline without reposting or redispatching work.


## Applied host drivers, setup and recovery

`hostDrivers` is canonical private configuration. Each entry fixes `machineId`, provider (`systemd`, `launchd`, `container`, `custom`), `environmentRoot` or null, supported `actions`, optional `networkApply`, `egressApply`, `setupRun`, and explicit `runtimeDestinations`. Each command is `{argv:string[],cwd:string,timeoutMs:number,probeArgv:string[]}`. Commands are reviewed executable manifests on the destination; product requests do not supply management shell commands. Keep isolated environment roots outside user home/SSH. Register only actions the driver actually supports.

Drivers execute over the destination's real node PTY. A stable operation ID and configuration/input digests accompany JSON input. The driver must return a bounded JSON-line receipt:

```json
{"type":"lemon_bot_host_result","version":1,"operationId":"persisted_operation_id","machineId":"machine_id","configDigest":"expected_digest","inputDigest":"expected_digest","state":"succeeded","exitCode":0}
```

`state` is `succeeded`, `skipped`, `failed`, `pending` or `not_found`; output must match exact operation/machine/digests. All receipt fields are **top-level**: network requires `appliedRevision`; egress requires `enabled`, `authenticated`, `encrypted`; setup requires `destinationSecretsOnly`, `secretsWiped`; host actions require `safePoint`, `retainedUserHome`, `retainedSSH`, plus `retainedDisk` and `retainedIdentity` for preserving actions. Recreate/delete additionally requires `isolatedEnvironment:true` and the exact `environmentRoot`. Inspection probes return actual `hostState`, `inactiveSinceMs`, `lastBackupAtMs`, and `environmentRoot`. `skipped` is honored only for host actions with exitCode 0 and explicit `skipReason` `already_current`, `already_stopped`, `environment_absent` or `unsupported`; it is not a successful action. An exit code alone is not proof of applied policy. Interrupted acknowledgment persists outcome_unknown and probes the **same operation ID**, never repeats a destructive command.

Setup manifests must exactly match reviewed operator `reviewedSetupManifests` entries (`name`, `directoryGroupId`, `machineIds`, ordered entries with stable `id`, `setupScript`, nullable `checkScript`, `secretNames`, `timeoutMs`). Maximum 30 minutes per entry. Check exit 0 skips; otherwise setup then recheck; only a measured successful recheck completes. The driver resolves named secrets destination-locally into the child environment and wipes transient material. No cross-group secret borrowing. Output is redacted before summaries/audit.

Network apply installs domain/IP/CIDR/port/protocol rules plus displayed operator runtime destinations. Pending/failed/offline/unsupported enforcement blocks new bot admission; UI desired revision is not applied revision. Egress requires source and through-machine authority plus an authenticated encrypted configured route. Central disable preserves the previous explicit preference but requires observed stop; re-enable cannot confer new host authority. Host previews bind every machine revision, command/root/configuration and loss/retention effects. Bulk phrase is `ACTION N machines` (single-machine exact name), up to 1000 targets, one active operation. Updating/recovering must observe a safe point and preserve user home/SSH. Recreate/delete affects only the reviewed isolated root, never the user's full machine.

Egress driver input includes a monotonically increasing `routeRevision`; the destination must reject older intents, including an uncertain enable superseded by central stop. A central stop has a 60-second observation deadline; maintenance reconciles every 45 seconds. Disconnect is not stop acknowledgment.

## Usage and provider-account reconciliation

UTC day, ISO Monday week and calendar month spend windows use actual priced native `usage.records` attribution. Each matching workspace/user/bot/routine limit is checked before new work. Missing/incomplete pricing or attribution is **unknown and denies new work under an enforced limit**, never a measured zero. Already-admitted work can finish over the limit. Own limits cannot bypass workspace ceilings; no owner-account billing fallback.

For an optional external provider account, configure a real reconciliation service under private `providerSpendSources`:

```json
{"providerSpendSources":[{"providerAccount":"provider-account-id","apiBaseUrl":"https://usage.example.com/lemon","secretRef":"provider-spend-token"}]}
```

The adapter issues authenticated `GET <apiBaseUrl>/spend` with `providerAccount`, `scope`, optional `subjectId`, `fromAtMs` and `toAtMs`. The service must reconcile **that exact account and product attribution**, returning `{providerAccount,scope,subjectId:null|string,currency:"USD",fromAtMs,toAtMs,costUsd:number|null,complete:boolean}`. Account/scope/window mismatches fail. Absent service or incomplete accounting remains unknown. A provider name is not inferred to be a provider account ID. The service can wrap the provider's authorized costs API and mapping ledger; it must not return invented attribution.

## Audit and content exports

Export destinations use operator-approved `exportAllowedOrigins`, HTTPS, no redirects, optional backend server `secretRef`, and `ndjson_webhook` or `otlp_http`. Private HTTPS collector exceptions additionally appear in private `exportPrivateOrigins`, a subset of `exportAllowedOrigins`. Audit/action/usage are separate streams, never arbitrary shell logs. Content is off by default and requires global enablement, requesting actor's actual conversation access and every current human participant's own consent. Admin status cannot expose another user's private DM.

Outbox delivery persists a stable idempotency key and cursor; enabling a stream starts at the current watermark, never automatic old-history backfill. Explicit historical exports use selected ranges/conversations, persist actual bytes as an ACL-bound attachment only after success, and recheck consent at dispatch and download. Revoking consent invalidates undelivered content and previously issued product download access; acknowledged external copies cannot be erased by a product toggle. Known credentials and secret-shaped keys are scrubbed, but operators must review residual personal-data risk.

## Voice and push

The backend consumes the voice/push environment variables in the product README. Configure the complete provider set, not just a capability flag:

- OpenAI STT: `LEMON_BOT_STT_PROVIDER=openai`, `LEMON_BOT_OPENAI_API_KEY`; actual Whisper multipart verbose transcription.
- Deepgram STT: `LEMON_BOT_STT_PROVIDER=deepgram`, `LEMON_BOT_DEEPGRAM_API_KEY`; actual Nova transcription bytes.
- OpenAI TTS: `LEMON_BOT_TTS_PROVIDER=openai` and OpenAI key; genuine provider WAV.
- ElevenLabs TTS: `LEMON_BOT_TTS_PROVIDER=elevenlabs`, `LEMON_BOT_ELEVENLABS_API_KEY`; real provider PCM converted to WAV. Full 0.5–2 speed uses provider-supported 0.7–1.2 synthesis plus resampling of genuine PCM outside that range; pitch can shift at extremes.
- Google TTS: `LEMON_BOT_TTS_PROVIDER=google`, private `LEMON_BOT_GOOGLE_SERVICE_ACCOUNT_PATH`; RS256 service-account OAuth token and actual LINEAR16 synthesis. Explicit language needs Cloud Text-to-Speech API. Null language means automatic detection and additionally needs the same service account's `project_id`, Cloud Translation v3 API and `cloudtranslate.languageDetectionModels.predict` permission; no guessed English or new environment variable.

Audio is sniffed, bounded to 25 MiB and ten minutes, and validated against configured formats (WAV/MP3/MP4/WebM/Ogg-Opus). Dictation never auto-sends; speech creates a real authorized attachment/download. No manufactured silence or text/hash masquerading as audio. Google credentials and APNs `.p8` are service-owned mode-0600 files.

APNs requires key ID, team ID, private key path and allowlisted topics (`LEMON_BOT_APNS_KEY_ID`, `...TEAM_ID`, `...PRIVATE_KEY_PATH`, `...TOPICS`). Delivery uses ES256 token auth over HTTP/2 and configured environment. `LEMON_BOT_APNS_ENVIRONMENTS` optionally narrows `sandbox,production`.

Web Push requires VAPID public/private key and contact subject (`LEMON_BOT_VAPID_PUBLIC_KEY`, `...PRIVATE_KEY`, `...SUBJECT`). Delivery uses RFC 8291 ECDH/HKDF/AES128GCM and signed VAPID, not plaintext push. `LEMON_BOT_WEB_PUSH_ORIGINS` replaces the exact HTTPS origin allowlist, default `https://fcm.googleapis.com,https://updates.push.services.mozilla.com,https://web.push.apple.com`. Endpoints resolve to public addresses; redirects are refused. Device credentials are write-only and cease delivery with account/session revocation. OS payload is intentionally generic: exact task/resource IDs and token-free deep link, no transcript, terminal, form or secret content. The authenticated inbox is authoritative; push is best effort.

## Central integration checks

This assignment intentionally runs no build/test/lint/format or live provider checks. After all slices integrate, the orchestrator should run backend TypeScript checks and `bun test` from `products/lemon_bot/backend`, then actual configured OAuth/SCIM/provider/PTY/notification smoke checks with private disposable credentials. Provider absence is an explicit deployment prerequisite, not evidence an operation was exercised.
