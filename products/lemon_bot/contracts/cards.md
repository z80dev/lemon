# Transcript entries and cards — Lemon Bot v1

Normative companion to [api.md](api.md) and [protocol.ts](protocol.ts). This adapts the installed Grok Bot 0.70.2 teardown's **27 typed messages**, not its bridge method names. A card is a typed durable entry, not generic Markdown containing buttons. Product policy, user identity, machine, conversation, entry, run and provider result are separate concepts.

## 1. Entry envelope, ordering, and presentation

Every `TranscriptEntry` is `EntryBase` plus an exhaustive `kind` payload. Base fields: `id`, `revision`, `createdAtMs`, `updatedAtMs`, `conversationId`, conversation-local `seq`, `timestampMs`, `actor:{kind,id,displayName}`, nullable `clientNonce`, `batchId`, `replyToEntryId`, `runId`, `targetedUserId`, and `reactions:[{emoji,userIds}]`. Author is not automatically the selected Bot. Group Bot replies/handoffs and humans must be attributed. `targetedUserId` restricts visibility/actions; it is not a cosmetic "Only Alice can answer" label over a leaked payload.

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

`TranscriptEvent` is exhaustive: name_changed(name), channel_connected/channel_disconnected(channelBindingId), routine_changed(routineId, action created/updated/paused/resumed/deleted), task_changed(conversationId,status), team_shared/team_bot_published/team_bot_unpublished(botId), person_added/person_removed/person_left(userId), bot_added/bot_removed(botId), handoff(sourceBotId,targetBotId,targetConversationId,text), machine_moved(botId,sourceMachineId,targetMachineId). No opaque event blobs. Routine activity may group; task opens independent task conversation, never a separate bot identity.

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
| 18 | team-access | `team_access` | Shared bot owner/published/unavailable identity; owner publishes through BotUpdate, manager maintains setup; user starts own private DM |
| 19 | slack-connect | `slack_connect` | Existing Lemon Slack adapter or real configured per-Bot Slack app OAuth/install provider; admin approval/link/thread/removal states |
| 20 | bot-template-share | `bot_template_share` | Workspace/public reviewed declarative copy, provenance/terms/import; deleted/policy blocked explicit |
| 21 | auto-review-approval | `auto_review_approval` | Proposed action + reviewer/rule context; Allow once/Deny, optional separate future-rule editor |
| 22 | connector-grant | `connector_grant` | Exact account owner consents Once/For this Bot/Decline; consent does not authorize unrelated writes |
| 23 | local-tool-permission | `local_tool_permission` | Exact destination machine command/file/tool proposal; workspace/local ceiling plus explicit one-time action approval |
| 24 | virtual-card-approval | **Payment instrument dropped**, purchase proposal uses `permission_request` category purchase | No issuing/charging card, wallet, payment-method picker or commerce entitlement. Actual provider/host purchase still requires ordinary consequence approval + human step if needed |
| 25 | cookie-origin-approval | **Cookie copying dropped**, existing destination browser login via `human_step` | Attached host keeps its own browser state; no desktop-cookie exfiltration/import facility or misleading per-bot security boundary |
| 26 | publish-approval | `publish_approval` | Generic external publish/deploy proposal; explicit action approval; separate from team publish/template audience change |
| 27 | mobile-tool-permission | **Native phone execution not supplied**, `local_tool_permission` or `human_step` on assigned swarm machine | iPhone is a client, not automatically a shell execution node. Phone permissions stay OS microphone/camera/push prompts; client cannot silently authorize another user's machine |

Additional Lemon cards `voice_memo` and `handoff` make real audio/durable task ownership explicit. The exhaustive `Card` union comprises: text, attachment, link, widget, secret_request, human_step, user_form, email_draft, slack_draft, message_draft, calendar_event, permission_request, auto_review_approval, local_tool_permission, publish_approval, connector, connectors, listener_connect, slack_connect, scm_connect, team_access, bot_template_share, connector_grant, voice_memo, handoff.

## 3. Durable action/gate model

`Gate` fields: id, state, targetUserId, expiresAtMs, nullable resolvedAtMs/resolvedByUserId, revision. Gate belongs to Approval/Question/HumanStep/SecretRequest/ConnectorConsent resource; those have entryId and their own revision. Gate/resource resolution is one atomic transaction (same increment), persisted before tool wakes. Send current resource revision, not guessed entry revision. State updates replace resource embedded in card and emit resource upsert plus entry upsert in same transaction; neither divergent duplicated resolution state nor client-only success.

`ResolutionState`: pending, submitted, approved, denied, declined, expired, cancelled, completed, failed, outcome_unknown. This union covers distinct workflows, **not** permission for every transition on every resource. A returned HTTP error may leave the gate pending only when server proves no external effect; state outcome_unknown fences ambiguous effects. Terminal states do not return to pending; new attempt requires bot creates new request with a new nonce after user requests retry. At expiresAtMs, pending becomes expired server-side; clients disable buttons even before event arrives. Resolution at/after expiry rejects expired; repeated already-successful **same nonce** replays original result. Two devices racing: first authorized transaction wins, second different nonce 409 conflict/revision_conflict with current resource ID/revision; UI refreshes, never overrides first choice.

| Workflow | Allowed state machine | Client resolution endpoint/body | Tool wake result |
|---|---|---|---|
| Approval family | pending→approved or denied; pending→expired/cancelled; reviewer/policy may approve/deny before rendering if not required ask_first. Approved is permission, never completed side effect | POST approvals/:id/resolve ApprovalResolve(decision approve_once/deny) | ApprovalToolResult decision approved/denied/expired/cancelled, no auto-execute on deny/timeout |
| Widget/question/form | pending→completed with validated answers; pending→declined; pending→expired/cancelled | POST questions/:id/resolve QuestionResolve(decision answer + answers, or decline) | QuestionToolResult.state and answers; declined/expired/cancelled answers null |
| Human step | pending→completed (done), pending→declined (skip), pending→expired/cancelled | POST human-steps/:id/resolve HumanStepResolve(done/skip) | HumanStepToolResult decision done/skipped/expired/cancelled; bot must verify actual login/result before claiming success |
| Secret request | pending→submitted→completed after destination encrypted storage acknowledgment; submitted→failed or outcome_unknown; pending→declined/expired/cancelled | POST secret-requests/:id/resolve SecretRequestResolve(save + value OR decline) | SecretToolResult.saved and name only. Value never returned/printed or put into entry |
| Connector consent | pending→approved (allow_once/allow_bot); pending→declined/expired/cancelled. Grant expiry/revoke disables future use; never replays prior action | POST consents/:id/resolve ConsentResolve; DELETE consents/:id revokes remembered grant | Appropriate connector usable only for verified granted principal/scope; no arbitrary form answer used as consent |
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
- **listener_connect/slack_connect:** adapter/account/target/events capability and real setup pending/awaiting_admin/connected/denied/failed state, install/auth/request/check/reopen/remove via actual configured provider. No fake connected account after Add; channel setup distinct from per-user MCP posting consent.
- **team_access:** owner byline, unpublished/published/unavailable, manager setup but owner publishes; collaborator starts own private DM. No private history/notes/credentials silently imported; directory default membership does not grant managerial authority.
- **bot_template_share:** name/provenance/audience/terms, Open details/Copy link/Import separate owned bot, explicit review for publish; deleted or policy-blocked link cannot import. No sender's original credentials/history or implicit memory copy.
- **connector_grant:** exact account-owner target, account label/server/bot/request context; Allow once/Allow this Bot/Decline; optional remembered expiry. Any other viewer sees no sensitive content. Remembered grant delete/reset acts on future use, not approvals for risky write operations.
- **voice_memo:** persisted audio waveform/length/transcript, preparing/playing/paused/fetch-failed, play/pause/seek/1×–1.5×–2× local playback, expand transcript. On-device fallback reading text must not pretend persisted audio available. No entitlement/payment gate.
- **handoff:** named specialist/source ownership/task, queued/working/completed/failed and target conversation link; actual artifacts/results remain discoverable in original authorized context. Does not recursively broadcast nor confer target permissions.

`CardAction` is the exhaustive persisted client-action union: answer, approve/deny, human_done/human_skip, secret_save/secret_decline, draft_edit/draft_send/draft_discard, connector_authorize/connector_consent, template_import, team_publish. Requests are exact resolve/edit types in protocol.ts. Local open/play/preview/copy/navigation are not server gate actions. Changing policies, connecting channel configuration, feedback and ordinary messages use their independent REST requests.

## 5. Context/actor restrictions and audit

Groups accept user inputs/files and bot files/text/questions/forms. Approvals, connector consent, secrets, drafts and human credential steps are **private** gates: backend routes to designated user's private task/DM and posts a minimal room notice referencing accessible destination. Never embed private draft body/credential/name into room with disabled buttons. A published Team Bot's owner/manager cannot read another user's private DM/notes. User authority is actual initiating member, inherited on allowed handoff/routine/channel turn; never fall back to owner authority or secretly charge owner on refusal.

Pending gates persist through client close; background deadline expires without action. Expired/declined/denied requests render retained terminal state, explanatory "No action was authorized" and optional Ask Bot to try again. A future rule change cannot revive one. Audit records actor, action, target IDs, sanitized category/result/requestId/time, not secret value/form sensitive content/draft provider credentials. Provider/host side effects must be accurately reported; action permission and successfully completed operation are separate milestones.

## 6. Companion/control and configured integration extensions

All card resources obey api.md §§10–11. Bot overview keeps one status anchor (idle/working/making/needs-input/offline plus assigned machine), distinct Identity/Job/Memory with inspectable PreferenceChange/Undo, Activity+Upcoming/task-aware output links and Ideas that only draft a prompt. Real making evidence and Attachment.provenance identify generating Bot/run/machine; no simulated success. Preference changes, reminder notifications, guided memory candidate previews, destructive scope review and milestones use typed resource screens rather than invented new Card types. Normal event/notice entries link their exact resources.

Confirmation.affected lists exact ScopeEffect IDs/machines/actions/retained explanation: conversation deletion leaves derived memory, memory forgetting leaves transcript/backups, connector disconnect leaves history and reports actual provider revoke/unknown, selected Bot reset preserves identity/host/unselected scopes. Attachment/memory/connector delete requires preview/token/revision/name; no offline destructive queue.

Guided memory import is source→candidate provenance/exclusions→checked confirmation→acknowledged memory.add, never whole-chat/credential/profile auto-import. Natural preferences require authorized user source entry and conflict-safe Undo. Approval scope badge is explanatory bounded authority, not carte blanche. Queued vs steering/interrupting comes from MessageReceipt.delivery actual worker acknowledgment.

Task-aware NotificationTarget/deepLink uses token-free lemonbot:// workspace/Bot/conversation/task/entry/approval/machine grammar; navigation never resolves gate. Optional once-per-Bot/user verified milestones are nonblocking and respect disabled celebrations/reduced motion. Explicit macOS PTT/mic cues/voice sample/review, global summon mini-composer, iOS share and web palette never ambient-listen or capture screen/clipboard history.

Connectors use explicitly approved machine MCP secretBindings and names-only node secrets with destination encrypted `${LEMON_SECRET:NAME}` expansion. Real configured OIDC/SCIM/directory policy, network applied revisions, egress/setup/owned-host operations, spend limits/audit exports, Slack app/channel/email/X mention providers remain actual scope with exact prerequisites. Their setup/progress/failed/unconfigured screens are not fake new card payloads; resulting actions still use existing consent/approval/draft/human-step families and inherited principal. Configured purchase tools can request ordinary scoped consequential approval, not a product wallet/virtual card facility.
