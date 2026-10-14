# Transcript entries and cards — Lemon Bot v1

Normative companion to [api.md](api.md) and [protocol.ts](protocol.ts). This adapts the installed Grok Bot 0.70.2 teardown's **27 typed messages**, not its bridge method names. A card is a typed durable entry, not generic Markdown containing buttons. Product policy, user identity, machine, conversation, entry, run and provider result are separate concepts.

## 1. Entry envelope, ordering, and presentation

Every `TranscriptEntry` is `EntryBase` plus an exhaustive `kind` payload. Base fields: `id`, `revision`, `createdAtMs`, `updatedAtMs`, `conversationId`, conversation-local `seq`, `timestampMs`, `actor:{kind,id,displayName}`, nullable `clientNonce`, `batchId`, `replyToEntryId`, `runId`, `targetedUserId`, and `reactions:[{emoji,userIds}]`. Attribute each owned Bot reply/handoff and the sole human owner accurately. `targetedUserId` is null or that same Bot/conversation owner, never another human's membership or manager grant.

- Workspace realtime `seq` is a decimal-string cursor, **different** from conversation entry number. Entry content updates preserve entry seq, increment revision. Sort by entry seq; entry IDs immutable. Deduplicate optimistic entries by nonce/batch, replacing optimistic IDs with returned IDs; never render a duplicate accepted message after reconnect.
- A authored message plus one `user_attachment` per input shares batchId/nonce. Group attachment rows under one message and quote; attachment-only sends supported. Quote preview uses referenced entry (text/image/file/link/missing) and never bypasses ACL.
- Streaming assistant message text is provisional; offset-checked delta append followed by authoritative full `entry.upserted` closes it. Failure/cancellation remains a Run state and notice, not a silently erased answer. Tool summaries are sanitized activity indicators, not raw arguments/secret-bearing terminal dumps.
- Read/unread, attention, typing/working, push delivery, feedback, and gate resolution are independent. Opening/playing/reacting/copying a card does **not** authorize anything. Card actions use the resource IDs and revision shown at time of explicit user action, plus a fresh clientNonce for that intent.
- All three clients render every declared entry/card. Unknown future discriminator: bounded unsupported-message presentation with update guidance, no invented resolving button. Preserve original entry ID and allow authorized text/file fallback where known. Never evaluate arbitrary embedded markup in privileged app origin.

| Entry kind | Exact additional payload | Rendering/action boundary |
|---|---|---|
| `message` | role user/assistant, text, streaming, attachmentIds | Markdown/text bubble; user trailing, assistant leading; copy/reply/react/feedback; sends through conversations messages |
| `card` | card: Card | Specialized taxonomy below; actionable resource authoritative |
| `user_attachment` | attachmentId | Grouped input attachment with type/name/size/preview/download |
| `tool_call` | tool, title, status started/completed/failed, nullable detail | Collapsed working activity/details, not a bubble for every raw invocation |
| `mcp_app` | connectorId, resourceUri, nullable snapshotAttachmentId, state available/unavailable/expired | Isolated rendered snapshot; missing/expired explicit, rerun request through chat; not arbitrary URL execution |
| `notice` | severity info/warning/error, text, nullable requestId | Compact notice/error tray; copy diagnostic ID; dismiss only local/inbox notice, no history deletion |
| `event` | event: TranscriptEvent | Small typed activity line; relevant resource navigation |
| `feedback` | feedback: Feedback | Good/bad/reason/comment; own feedback saved, no action approval |
| `voice_call` | voiceSession: VoiceSession | Voice chat duration/state/transcript entry links/feedback; play memo is a separate card |

`TranscriptEvent` is exhaustive: name_changed(name), channel_connected/channel_disconnected(channelBindingId), routine_changed(routineId, action created/updated/paused/resumed/deleted), task_changed(conversationId,status), bot_added/bot_removed(botId), handoff(sourceBotId,targetBotId,targetConversationId,text), machine_moved(botId,sourceMachineId,targetMachineId). No Team publishing/sharing or other-human membership events. Routine activity may group; task opens an owned task conversation, never a separate human or bot identity.

## 2. Mapping every original typed-message family

Original names are evidence vocabulary; only Lemon's snake_case `Card.type` values are wire values. There are no compatibility aliases. Explicit dropping of vendor/payment/cookie/native phone facilities is a product mapping, not an unfinished implementation.

| # | Grok typed message | Lemon Card / decision | Meaning and resolving action |
|---|---|---|---|
| 1 | text | `text`; audio variation `voice_memo` | Normal text card; memo stores real audio attachment and transcript, local play/pause/seek/rate/expand |
| 2 | attachment | `attachment`, plus `link` | Immutable authorized attachment or external HTTP(S) source link; preview/download/open only |
| 3 | widget | `widget` | Select question options; Answer/Decline via questions/:id/resolve |
| 4 | cursor-agent | **Vendor card dropped**, native `handoff` and task_changed replace delegation outcome | Native Lemon Bot specialist/task, not Cursor Cloud Agent/VM or Open in Cursor. No vendor token/computer API |
| 5 | secret-request | `secret_request` | Targeted masked input; Save securely/Decline, write-only destination secret storage |
| 6 | credential-request | `human_step` | User uses own machine/browser/SSH/terminal for login/MFA; Done/Skip. No brokered password-manager auto-fill promise |
| 7 | user-form | `user_form` | Non-secret structured fields, required/options/ranges, Submit/Decline via question resolution |
| 8 | email-draft | `email_draft` | Editable email full recipients/from/body/attachments; Send/Discard, no unattended send |
| 9 | slack-draft | `slack_draft` | Editable Slack workspace/target/thread/body/attachments; Send/Discard via actual configured connector |
| 10 | meeting-chat-draft | `message_draft` | Configured channel message draft; no invented live meeting provider/internal-meeting bypass |
| 11 | calendar-event | `calendar_event` | Subject/start/end/timezone/all-day/guests/location/source/status preview; proposed change still requires independent approval |
| 12 | permission-request | `permission_request` | Generic proposed action category/target/inputs; Allow once/Deny via Approval |
| 13 | connector | `connector` | Single MCP connection state; configure/auth/retry/remove on connect.apps; opening auth is not consent |
| 14 | connectors | `connectors` | List of typed Connector rows, same states/actions as single |
| 15 | listener-connect | `listener_connect` | Configured channel/event adapter connection; account/target/enable state; actual server capability required |
| 16 | scm-connect | `scm_connect` | Source-control MCP connection/provider/reason; navigate verified Connector configuration/auth |
| 17 | onepassword-connect | **Dropped** | No password-manager vendor integration claimed. Use machine human step or named write-only secret, not a fake 1Password connection |
| 18 | team-access | **Dropped by current owner-only user scope** | No live Team Bots, managers, publishing, directory live grants or other-human DMs. Declarative template imports create separate personally owned Bots. |
| 19 | slack-connect | `slack_connect` | Existing Lemon Slack adapter or real configured per-Bot Slack app OAuth/install provider; admin approval/link/thread/removal states |
| 20 | bot-template-share | `bot_template_share` | Workspace/public reviewed declarative copy, provenance/terms/import; deleted/policy blocked explicit |
| 21 | auto-review-approval | `auto_review_approval` | Proposed action + reviewer/rule context; Allow once/Deny, optional separate future-rule editor |
| 22 | connector-grant | **Cross-human account-lending card dropped** | Bot/account/actual actor must be the same owner. Real native tool-policy/capability review remains; no replacement own-account consent layer. |
| 23 | local-tool-permission | `local_tool_permission` | Exact destination machine command/file/tool proposal; workspace/local ceiling plus explicit one-time action approval |
| 24 | virtual-card-approval | **Payment instrument dropped**, purchase proposal uses `permission_request` category purchase | No issuing/charging card, wallet, payment-method picker or commerce entitlement. Actual provider/host purchase still requires ordinary consequence approval + human step if needed |
| 25 | cookie-origin-approval | **Cookie copying dropped**, existing destination browser login via `human_step` | Attached host keeps its own browser state; no desktop-cookie exfiltration/import facility or misleading per-bot security boundary |
| 26 | publish-approval | `publish_approval` | Generic external publish/deploy proposal; explicit action approval; separate from reviewed declarative template audience change, never live Bot publishing |
| 27 | mobile-tool-permission | **Native phone execution not supplied**, `local_tool_permission` or `human_step` on assigned swarm machine | iPhone is a client, not automatically a shell execution node. Phone permissions stay OS microphone/camera/push prompts; client cannot silently authorize another user's machine |

Additional Lemon cards `voice_memo` and `handoff` make real audio/durable task ownership explicit. The exhaustive 23-value `Card.type` union comprises: text, attachment, link, widget, secret_request, human_step, user_form, email_draft, slack_draft, message_draft, calendar_event, permission_request, auto_review_approval, local_tool_permission, publish_approval, connector, connectors, listener_connect, slack_connect, scm_connect, bot_template_share, voice_memo, handoff. Original families 18 and 22 are explicit current-user decisions, not missing implementations or compatibility aliases.

## 3. Durable action/gate model

`Gate` fields: id, state, targetUserId, expiresAtMs, nullable resolvedAtMs/resolvedByUserId, revision. Gate belongs to Approval/Question/HumanStep/SecretRequest resource; those have entryId and their own revision. The target must be the same actual Bot/conversation owner. Gate/resource resolution is one atomic transaction (same increment), persisted before tool wakes. Send current resource revision, not guessed entry revision. State updates replace resource embedded in card and emit resource upsert plus entry upsert in same transaction; neither divergent duplicated resolution state nor client-only success.

`ResolutionState`: pending, submitted, approved, denied, declined, expired, cancelled, completed, failed, outcome_unknown. This union covers distinct workflows, **not** permission for every transition on every resource. A returned HTTP error may leave the gate pending only when server proves no external effect; state outcome_unknown fences ambiguous effects. Terminal states do not return to pending; new attempt requires bot creates new request with a new nonce after user requests retry. At expiresAtMs, pending becomes expired server-side; clients disable buttons even before event arrives. Resolution at/after expiry rejects expired; repeated already-successful **same nonce** replays original result. Two devices racing: first authorized transaction wins, second different nonce 409 conflict/revision_conflict with current resource ID/revision; UI refreshes, never overrides first choice.

| Workflow | Allowed state machine | Client resolution endpoint/body | Tool wake result |
|---|---|---|---|
| Approval family | pending→approved or denied; pending→expired/cancelled; reviewer/policy may approve/deny before rendering if not required ask_first. Approved is permission, never completed side effect | POST approvals/:id/resolve ApprovalResolve(decision approve_once/deny) | ApprovalToolResult decision approved/denied/expired/cancelled, no auto-execute on deny/timeout |
| Widget/question/form | pending→completed with validated answers; pending→declined; pending→expired/cancelled | POST questions/:id/resolve QuestionResolve(decision answer + answers, or decline) | QuestionToolResult.state and answers; declined/expired/cancelled answers null |
| Human step | pending→completed (done), pending→declined (skip), pending→expired/cancelled | POST human-steps/:id/resolve HumanStepResolve(done/skip) | HumanStepToolResult decision done/skipped/expired/cancelled; bot must verify actual login/result before claiming success |
| Secret request | pending→submitted→completed after destination encrypted storage acknowledgment; submitted→failed or outcome_unknown; pending→declined/expired/cancelled | POST secret-requests/:id/resolve SecretRequestResolve(save + value OR decline) | SecretToolResult.saved and name only. Value never returned/printed or put into entry |
| Draft | editable→sending→sent; editable→discarded; sending→failed or outcome_unknown; failed→editable only after confirmed unsent outcome reconciliation. Unknown never retry automatically | PATCH drafts/:id DraftUpdate; POST send DraftSend; POST discard Update | create_draft returns immediately editable; later follow-up run carries explicit exact-content signed authorization |
| Connector authorization | added/needs_auth/disconnected/failed→auth pending→connected OR denied/expired/failed; configured policy→blocked; actual discovery required for connected | POST connectors/:id/auth, verify OAuth callback state/code; PATCH config; DELETE | ConnectorAuth response, connector + auth upserts; not a blocking user secret tool |
| Channel connection | configured→connected/disconnected/failed; policy→blocked; disable sets enabled false independent from connection state | channels create/update/delete | Real adapter capabilities/state only; not hidden fake installation |
| Native handoff | queued→working→completed/failed | Navigation to target allowed task/DM; Stop cancels verified Run | message_bot/handoff returns asynchronous receipt, later results in requested authorized room |
| Voice chat | active→ended or failed | voice sessions mute/settings/end, normal messages/STT/TTS | One terminal voice_call entry; follow-up work continues in chat |
| Attachment/template/link/calendar/text/memo | Immutable/read-only card view; underlying template/channel/calendar may update through owning resource | Open/Preview/Download/Copy/Play/Pause/Import where specified | No implicit approval or blocking side effect |

For widget, exactly one Question select field with id `selection`; single-select answer is string option value, multiselect is unique string array. No label-as-authoritative-value. user_form uses fields IDs and types, optional fields absent, required ones validated server-side. Fields are ordinary model-visible input: UI must clearly say **not for passwords, OTPs or confidential credentials**. Secure values use masked secret_request or external human login, never ordinary fields. Calendar preview is not a calendar mutation: explicit requested change goes through permitted tool and approval/draft boundary.

## 4. Per-card UI/actions

- **text/link/attachment:** Markdown, source URL host shown, safe browser open, filename/type/size, preview/download, copy/reply/reaction. HTTP(S) external link is navigated by user, not fetched by privileged backend; attachment has ID→authorized short-lived URL, not a raw machine path.
- **widget/user_form:** prompt/title, labelled controls/options/errors; disabled/other-user/expired labels; Submit and Decline. Retain unsent local answers on transport failure, never show Completed before authoritative resolution. Ordinary select value submission cannot silently invoke another card action.
- **secret_request:** show name/scope/description/destination and shared-host warning; masked input, Save securely/Decline; erase client buffer after save/cancel; no password echo, copy value, persisted draft or crash log. Write-only means product avoids exposing to model; privileged machine owner remains in control of host. Failure must not say Saved.
- **human_step:** action-needed title/reason/instructions; Open machine, Open terminal if host access, optional verified HTTPS externalUrl opened explicitly; Done and Skip. No nonexistent desktop preview, auto-fill, CAPTCHA bypass, hidden cookie copying or permission to ask secret in chat. "I'm done" affirms user attempted step, bot rechecks.
- **email_draft/slack_draft/message_draft:** editable exact current recipients/target/thread/body/attachments and source identity, Send/Discard, sending spinner, sent/discarded/failed/not-confirmed. No reaction-as-Send and no unattended mode. Server stores edited content atomically with send authorization; discard never aborts an already possibly-sent provider effect. Unknown copy tells user to inspect actual provider before another send; Retry available only confirmed unsent.
- **approval family:** plain-language action/task summary, Bot+machine provenance, concrete target/inputs/reason/consequences/expiry and ReviewScope once/run/site/connector badge, reviewer/required-rule labels; Allow once/Deny. Never show blanket Always allow for destructive/financial/permission-changing/outward communication. A supported narrow future rule is separate recorded/revocable policy, not revived expiry or proof action executed. Exact phone deep-link fetches authorized current request.
- **connector(s)/scm_connect:** app/account identity, Added/Connected/Needs auth/Disconnected/Blocked/Failed distinct; Configure/Authenticate/Reopen/Reconnect/Retry/Remove based on real state. Product block and provider admin denial separate error messages. No assuming installed == authorized.
- **listener_connect/slack_connect:** adapter/account/target/events capability and real setup pending/awaiting_admin/connected/denied/failed state, install/auth/request/check/reopen/remove via actual configured provider. No fake connected account after Add; actual verified external sender must map to this Bot's same human owner.
- **bot_template_share:** name/provenance/audience/terms, Open details/Copy link/Import separate owned bot, explicit review for publish; deleted or policy-blocked link cannot import. No sender's original credentials/history or implicit memory copy.
- **voice_memo:** persisted audio waveform/length/transcript, preparing/playing/paused/fetch-failed, play/pause/seek/1×–1.5×–2× local playback, expand transcript. On-device fallback reading text must not pretend persisted audio available. No entitlement/payment gate.
- **handoff:** named specialist/source ownership/task, queued/working/completed/failed and target conversation link; actual artifacts/results remain discoverable in original authorized context. Does not recursively broadcast nor confer target permissions.

`CardAction` is the exhaustive persisted client-action union: answer, approve/deny, human_done/human_skip, secret_save/secret_decline, draft_edit/draft_send/draft_discard, connector_authorize, template_import. Requests are exact resolve/edit types in protocol.ts. No team_publish/connector_consent aliases. Local open/play/preview/copy/navigation are not server gate actions. Changing policies, channel configuration, feedback and ordinary messages use independent REST requests.

## 5. Context/actor restrictions and audit

Every live Bot and associated entry/card/run requires actual actor.userId === Bot.ownerUserId. Group contains 2–6 Bots owned by that one human, never other humans. Normal approvals/questions/drafts/human steps remain owner-authorized in the same room; no cross-human private-redirect/fallback layer. Credentials never enter ordinary fields/transcript/events. Handoff/routine/channel/helper retains the original actual owner actor, never rewrites a different human as owner or borrows an administrator/account token. Workspace roles/directories/public templates do not grant another live Bot. Foreign Bot requests are not_found without implicit clone or private fallback.

Pending gates persist through client close; background deadline expires without action. Expired/declined/denied requests render retained terminal state, explanatory "No action was authorized" and optional Ask Bot to try again. A future rule change cannot revive one. Audit records actor, action, target IDs, sanitized category/result/requestId/time, not secret value/form sensitive content/draft provider credentials. Provider/host side effects must be accurately reported; action permission and successfully completed operation are separate milestones.

## 6. Companion/control and configured integration extensions

All card resources obey api.md §§10–11. Bot overview keeps one status anchor (idle/working/making/needs-input/offline plus assigned machine), distinct Identity/Job/Memory with inspectable PreferenceChange/Undo, Activity+Upcoming/task-aware output links and Ideas that only draft a prompt. Real making evidence and Attachment.provenance identify generating Bot/run/machine; no simulated success. Preference changes, reminder notifications, guided memory candidate previews, destructive scope review and milestones use typed resource screens rather than invented new Card types. Normal event/notice entries link their exact resources.

Confirmation.affected lists exact ScopeEffect IDs/machines/actions/retained explanation: conversation deletion leaves derived memory, memory forgetting leaves transcript/backups, connector disconnect leaves history and reports actual provider revoke/unknown, selected Bot reset preserves identity/host/unselected scopes. Attachment/memory/connector delete requires preview/token/revision/name; no offline destructive queue.

Guided memory import is source→candidate provenance/exclusions→checked confirmation→acknowledged memory.add, never whole-chat/credential/profile auto-import. Natural preferences require authorized user source entry and conflict-safe Undo. Approval scope badge is explanatory bounded authority, not carte blanche. Queued vs steering/interrupting comes from MessageReceipt.delivery actual worker acknowledgment.

Task-aware NotificationTarget/deepLink uses token-free lemonbot:// workspace/Bot/conversation/task/entry/approval/machine grammar; navigation never resolves gate. Optional once-per-Bot/user verified milestones are nonblocking and respect disabled celebrations/reduced motion. Explicit macOS PTT/mic cues/voice sample/review, global summon mini-composer, iOS share and web palette never ambient-listen or capture screen/clipboard history.

Connectors use explicitly approved machine MCP secretBindings and names-only node secrets with destination encrypted `${LEMON_SECRET:NAME}` expansion. Actual account/Bot/actor owners match. Optional existing configured OIDC/SCIM/directory policy, applied network/egress/setup/host operations, spend/audit/export and channel/email/X provider controls remain server/operator facilities, not enterprise-first owner onboarding or live Bot grants. Real permission/draft/human-step families represent actual requested work; no ConnectorConsent lending layer. Configured purchases use ordinary scoped consequential approval, not a wallet/virtual card.

## 7. Persistent iPhone pairing is account security, not a Bot card

The desktop/browser `device.pairing` panel presents a short-lived QR plus exact reachable cluster URL, then the requesting device name and matching six-digit verificationCode. `Pairing` owns this state, separate from `Gate`, `Card`, transcript and MCP. Bots cannot issue/approve pairings or solicit permanent credentials through a question/card. No new Card.type is invented.

State machine: waiting → pending_approval after one-use claim; pending_approval → approved or denied by issuing human; waiting/pending_approval/approved → expired at original five-minute deadline; approved → consumed on successful completion. Successful completion privately returns the same persistent Device/AuthSession, not another account or Bot. `pairing.upserted` contains only safe Pairing metadata for the issuing owner's authenticated devices, never pairUrl/pairCode/claimToken/AuthResult.token.

iOS scans/pastes strict `lemonbot://pair`, performs non-consuming PairingPreviewRequest, and shows verified exact clusterName/backendUrl before explicit Claim. Scanning/preview never connects, approves or starts work. Desktop Approve uses PairingApprove with current revision and displayed verificationCode; Deny uses PairingDeny. Phone polls PairingComplete with one fixed clientNonce, showing pending/denied/expired or connected. Same encrypted completion receipt replays the same device/session only until original deadline; no second mint. The phone stores connected token in Keychain and restores the saved cluster/account/Bot/conversation after reopen.

Pairing QR is deliberately secret-bearing and short-lived, unlike token-free task Notification deep links; never place it in transcript/push/audit/logs or ordinary navigation history. Normal auth/devices list and revoke manage the persistent paired session (`expiresAtMs:null` until revoked). Offline retains saved connection without replaying work; revoked/disabled authority shows Reconnect, never silently impersonates another actor or retrieves an operator token. No hosted network, Tailscale provisioning or phone shell execution is implied.
