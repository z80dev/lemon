/** Lemon Bot wire protocol v1. No runtime dependencies. See api.md for validation and ACLs. */
export type ID = string;
export type Cursor = string;
export type TimestampMs = number;
export type JSONValue = null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue };
export type JSONObject = { [key: string]: JSONValue };
export type Role = 'owner' | 'admin' | 'member';
export interface Resource { id: ID; revision: number; createdAtMs: TimestampMs; updatedAtMs: TimestampMs }
export interface Page<T> { items: T[]; nextCursor: Cursor | null }
export interface PageQuery { cursor?: Cursor; limit?: number }
export interface Mutation { clientNonce: string }
export interface Update extends Mutation { revision: number }
export interface Confirm extends Update { confirmationToken: string; confirmName: string }
export interface PreviewRequest extends Mutation { action: 'delete' | 'detach' | 'move' | 'forget' | 'disconnect' | 'reset'; targetMachineId?: ID; resetScopes?: BotResetScope[] }
export interface Confirmation { confirmationToken: string; revision: number; confirmName: string; expiresAtMs: TimestampMs; effects: string[]; affected: ScopeEffect[] }
export interface Deleted { id: ID; deleted: true }
export interface Empty { ok: true }
export type BinaryBody = Uint8Array;
export interface OAuthCallbackQuery { state: string; code?: string; error?: string }
export type ErrorCode = 'invalid_request' | 'unauthenticated' | 'forbidden' | 'not_found' | 'conflict' | 'nonce_conflict' | 'revision_conflict' | 'confirmation_required' | 'expired' | 'too_large' | 'unsupported_media' | 'rate_limited' | 'machine_offline' | 'upstream_unavailable' | 'capability_unavailable' | 'policy_denied' | 'outcome_unknown' | 'cursor_expired' | 'internal_error';
export interface ErrorEnvelope { error: { code: ErrorCode; message: string; requestId: string; retrySafe: boolean; details?: JSONObject } }
export interface VoiceSettings { voiceId: string; speed: number; language: string | null }
export interface Preferences { appearance: 'system' | 'light' | 'dark'; language: string | null; timezone: string; botColors: boolean; threadsBesideChat: boolean; voice: VoiceSettings; celebrationsEnabled: boolean }
export interface NotificationPreferences { enabled: boolean; sound: boolean; previews: boolean; completed: boolean; needsInput: boolean }
export interface User extends Resource { email: string; displayName: string; avatarAttachmentId: ID | null; preferences: Preferences; notifications: NotificationPreferences }
export interface Workspace extends Resource { name: string; ownerUserId: ID; enabled: boolean; timezone: string }
export interface Member extends Resource { userId: ID; displayName: string; email: string; role: Role; enabled: boolean }
export interface MemberInvite extends Resource { email: string; role: 'admin' | 'member'; expiresAtMs: TimestampMs; status: 'pending' | 'accepted' | 'revoked' | 'expired' }
export interface AuthSession extends Resource { userId: ID; deviceId: ID | null; expiresAtMs: TimestampMs; lastSeenAtMs: TimestampMs; current: boolean }
export interface AuthResult { token: string; session: AuthSession; user: User; workspace: Workspace; member: Member }
export interface SetupStatus { setupRequired: boolean; version: string; apiVersion: 1 }
export interface SetupRequest extends Mutation { setupCode: string; email: string; password: string; displayName: string; workspaceName: string }
export interface LoginRequest extends Mutation { email: string; password: string; deviceId?: ID }
export interface AcceptInviteRequest extends Mutation { inviteToken: string; email: string; password: string; displayName: string }
export interface ReauthRequest { password: string }
export interface ReauthResult { reauthToken: string; expiresAtMs: TimestampMs }
export interface UserUpdate extends Update { displayName?: string; email?: string; avatarAttachmentId?: ID | null; preferences?: Preferences; notifications?: NotificationPreferences }
export interface PasswordUpdate extends Mutation { currentPassword: string; newPassword: string }
export interface AccountDelete extends Confirm { reauthToken: string }
export interface WorkspaceUpdate extends Update { name?: string; timezone?: string; enabled?: boolean; ownerUserId?: ID }
export interface MemberUpdate extends Update { role?: Role; enabled?: boolean }
export interface InviteCreate extends Mutation { email: string; role: 'admin' | 'member'; expiresInMs?: number }
export interface InviteIssued { invite: MemberInvite; inviteToken: string; inviteUrl: string }
export type PushRegistration = { kind: 'apns'; token: string; environment: 'sandbox' | 'production'; topic: string } | { kind: 'web_push'; endpoint: string; keys: { p256dh: string; auth: string } };
export interface Device extends Resource { userId: ID; platform: 'web' | 'macos' | 'ios'; name: string; appVersion: string; pushEnabled: boolean; lastSeenAtMs: TimestampMs }
export interface DeviceRegister extends Mutation { installationId: string; platform: Device['platform']; name: string; appVersion: string; push?: PushRegistration }
export interface DeviceUpdate extends Update { name?: string; appVersion?: string; push?: PushRegistration | null; pushEnabled?: boolean }
export interface Capabilities { controlConnected: boolean; methods: string[]; stt: boolean; tts: boolean; imageGeneration: boolean; apns: boolean; webPush: boolean; vapidPublicKey: string | null; attachmentMaxBytes: number; videoMaxBytes: number; maxAttachments: number; minClientVersions: { web: string; macos: string; ios: string } }
export interface Machine extends Resource { nodeId: ID | null; nodeName: string; name: string; ownerUserId: ID; accessUserIds: ID[]; status: 'pending' | 'online' | 'offline' | 'revoked'; lastSeenAtMs: TimestampMs | null; labels: Record<string, string>; botIds: ID[] }
export interface HostInfo { hostname: string; os: string; osVersion: string; arch: string; cpuCount: number; memTotalBytes: number; memFreeBytes: number; diskTotalBytes: number; diskFreeBytes: number; uptimeSec: number; lemonVersion: string; defaultCwd: string; user: string; measuredAtMs: TimestampMs }
export interface MachineInvite extends Resource { machineId: ID; inviteCode: string; joinCommand: string; expiresAtMs: TimestampMs; status: 'pending' | 'joined' | 'expired' | 'revoked'; enrollment: 'invited' | 'waiting_for_join' | 'connecting' | 'verifying' | 'online' | 'expired' | 'failed' | 'revoked'; lastError: string | null }
export interface MachineAttach extends Mutation { name: string; nodeName: string; labels?: Record<string, string>; expiresInMs?: number }
export interface MachineAttachResult { machine: Machine; invite: MachineInvite }
export interface MachineUpdate extends Update { name?: string; accessUserIds?: ID[]; labels?: Record<string, string> }
export interface MachineReconnect extends Mutation { expiresInMs?: number }
export interface FileInfo { path: string; name: string; kind: 'file' | 'directory' | 'symlink'; size: number; mime: string | null; modifiedAtMs: TimestampMs; readable: boolean; writable: boolean }
export interface FileListQuery extends PageQuery { path: string; showHidden?: boolean }
export interface FilePathQuery { path: string }
export interface FileReadQuery extends FilePathQuery { offset?: number; length?: number }
/** size is TOTAL source-file bytes; offset is chunk start, chunk length is decoded dataBase64 bytes, eof is actual source end. */
export interface FileChunk { path: string; offset: number; dataBase64: string; size: number; mime: string; eof: boolean }
export interface FileWrite extends Mutation { path: string; dataBase64: string; offset?: number; truncate?: boolean; mkdirs?: boolean; expectedModifiedAtMs?: TimestampMs }
export interface FileMkdir extends Mutation { path: string }
export interface FileMove extends Mutation { path: string; destination: string; expectedModifiedAtMs: TimestampMs }
export interface FileDelete extends Mutation { path: string; confirmationToken: string; confirmName: string }
export interface FilePreview extends Mutation { path: string; action: 'delete' }
export interface Secret extends Resource { name: string; description: string; scope: 'machine' | 'bot'; botId: ID | null }
export interface SecretSet extends Mutation { description: string; value: string; scope: 'machine' | 'bot'; botId?: ID }
export interface Terminal extends Resource { machineId: ID; userId: ID; deviceId: ID; cwd: string; cols: number; rows: number; state: 'open' | 'closed'; exitCode: number | null }
export interface TerminalOpen extends Mutation { deviceId: ID; cwd?: string; cols: number; rows: number }
export interface TerminalInput extends Mutation { dataBase64: string }
export interface TerminalResize extends Mutation { cols: number; rows: number }
export interface Avatar { kind: 'character' | 'image'; shape: string; color: string; attachmentId: ID | null }
export interface SidebarState { pinned: boolean; hidden: boolean; sectionId: ID | null; rank: number; unread: boolean; notificationsEnabled: boolean }
export interface Bot extends Resource { ownerUserId: ID; managerUserIds: ID[]; machineId: ID; profileId: string; name: string; title: string; job: string; instructions: string; avatar: Avatar; voice: VoiceSettings; language: string | null; visibility: 'personal' | 'team'; published: boolean; required: boolean; skillIds: ID[]; referenceAttachmentIds: ID[]; mainConversationId: ID; sidebar: SidebarState; activity: BotPresence['status']; activeRunIds: ID[] }
export interface BotCreate extends Mutation { name: string; machineId: ID; title?: string; job?: string; instructions?: string; avatar?: Avatar; voice?: VoiceSettings; language?: string | null; visibility?: Bot['visibility']; skillIds?: ID[]; templateId?: ID }
export interface BotUpdate extends Update { name?: string; title?: string; job?: string; instructions?: string; avatar?: Avatar; voice?: VoiceSettings; language?: string | null; managerUserIds?: ID[]; published?: boolean; required?: boolean; skillIds?: ID[]; referenceAttachmentIds?: ID[] }
export interface BotDuplicate extends Mutation { name: string; machineId: ID; includeSkills: boolean; includeRoutines: boolean }
export interface BotMove extends Confirm { machineId: ID }
export interface BotTeamCopy extends Mutation { name: string; machineId: ID; memoryIds: ID[]; skillIds: ID[]; referenceAttachmentIds: ID[]; routineIds: ID[]; connectorIds: ID[] }
export interface SidebarUpdate extends Update { pinned?: boolean; hidden?: boolean; sectionId?: ID | null; rank?: number; unread?: boolean; notificationsEnabled?: boolean }
export interface AvatarGenerate extends Mutation { prompt: string }
export interface Section extends Resource { userId: ID; name: string; rank: number; collapsed: boolean }
export interface SectionCreate extends Mutation { name: string; rank?: number }
export interface SectionUpdate extends Update { name?: string; rank?: number; collapsed?: boolean }
export interface TemplateContent { name: string; title: string; job: string; instructions: string; avatar: Avatar; voice: VoiceSettings; skills: { name: string; description: string; markdown: string }[]; routines: RoutineSpec[]; connectorNames: string[] }
export interface BotTemplate extends Resource { ownerUserId: ID; audience: 'workspace' | 'public'; sourceBotId: ID | null; content: TemplateContent; provenance: { publisher: string; sourceUrl: string | null; termsUrl: string | null; thirdParty: boolean }; shareUrl: string }
export interface TemplateCreate extends Mutation { botId: ID; audience: BotTemplate['audience']; reviewed: true }
export interface TemplateUpdate extends Update { audience?: BotTemplate['audience']; content?: TemplateContent; reviewed: true }
export interface TemplateImport extends Mutation { name: string; machineId: ID; acceptedTerms: boolean }
export type ConversationKind = 'dm' | 'task' | 'team_dm' | 'group' | 'channel';
export interface Conversation extends Resource { kind: ConversationKind; name: string; botIds: ID[]; humanUserIds: ID[]; ownerUserId: ID; parentConversationId: ID | null; leadBotId: ID | null; channelBindingId: ID | null; lastEntryId: ID | null; unreadCount: number; lastReadSeq: number; activity: { botId: ID; phase: 'reading' | 'working' | 'typing' }[] }
export interface ConversationCreate extends Mutation { kind: ConversationKind; name?: string; botIds: ID[]; humanUserIds?: ID[]; parentConversationId?: ID; leadBotId?: ID }
export interface ConversationUpdate extends Update { name?: string; botIds?: ID[]; humanUserIds?: ID[]; leadBotId?: ID | null }
export interface ReadRequest extends Mutation { throughSeq: number; unread?: boolean }
export interface ComposerDraft { conversationId: ID; text: string; attachmentIds: ID[]; replyToEntryId: ID | null; updatedAtMs: TimestampMs; revision: number }
export interface ComposerDraftUpdate extends Update { text: string; attachmentIds: ID[]; replyToEntryId?: ID | null }
export type Reference = { kind: 'bot' | 'routine' | 'skill' | 'connector' | 'group'; id: ID };
export interface MessageSend extends Mutation { text: string; attachmentIds?: ID[]; replyToEntryId?: ID; mentions?: ID[]; everyone?: boolean; references?: Reference[]; mode?: 'followup' | 'steer' | 'interrupt'; voiceSessionId?: ID }
export interface Run extends Resource { conversationId: ID; botId: ID; initiatorUserId: ID; clientNonce: string; status: 'reserved' | 'queued' | 'running' | 'awaiting_input' | 'succeeded' | 'failed' | 'cancelled' | 'outcome_unknown'; error: ErrorEnvelope['error'] | null; startedAtMs: TimestampMs | null; completedAtMs: TimestampMs | null; routineRunId: ID | null }
export interface MessageReceipt { entries: TranscriptEntry[]; runs: Run[]; clientNonce: string; status: 'accepted' | 'queued' | 'outcome_unknown'; delivery: { botId: ID; requestedMode: 'followup' | 'steer' | 'interrupt'; effectiveMode: 'queued' | 'steering' | 'interrupting' | 'started' | 'outcome_unknown'; targetRunId: ID | null; runId: ID }[] }
export interface RunCancel extends Mutation { reason?: string }
export type Actor = { kind: 'user' | 'bot' | 'system'; id: ID | null; displayName: string };
export interface Reaction { emoji: string; userIds: ID[] }
export interface EntryBase extends Resource { conversationId: ID; seq: number; timestampMs: TimestampMs; actor: Actor; clientNonce: string | null; batchId: ID | null; replyToEntryId: ID | null; runId: ID | null; targetedUserId: ID | null; reactions: Reaction[] }
export type TranscriptEntry = EntryBase & (
  | { kind: 'message'; role: 'user' | 'assistant'; text: string; streaming: boolean; attachmentIds: ID[] }
  | { kind: 'card'; card: Card }
  | { kind: 'user_attachment'; attachmentId: ID }
  | { kind: 'tool_call'; tool: string; title: string; status: 'started' | 'completed' | 'failed'; detail: string | null }
  | { kind: 'mcp_app'; connectorId: ID; resourceUri: string; snapshotAttachmentId: ID | null; state: 'available' | 'unavailable' | 'expired' }
  | { kind: 'notice'; severity: 'info' | 'warning' | 'error'; text: string; requestId: string | null }
  | { kind: 'event'; event: TranscriptEvent }
  | { kind: 'feedback'; feedback: Feedback }
  | { kind: 'voice_call'; voiceSession: VoiceSession }
);
export type TranscriptEvent =
  | { type: 'name_changed'; name: string }
  | { type: 'channel_connected' | 'channel_disconnected'; channelBindingId: ID }
  | { type: 'routine_changed'; routineId: ID; action: 'created' | 'updated' | 'paused' | 'resumed' | 'deleted' }
  | { type: 'task_changed'; conversationId: ID; status: Run['status'] }
  | { type: 'team_shared' | 'team_bot_published' | 'team_bot_unpublished'; botId: ID }
  | { type: 'person_added' | 'person_removed' | 'person_left'; userId: ID }
  | { type: 'bot_added' | 'bot_removed'; botId: ID }
  | { type: 'handoff'; sourceBotId: ID; targetBotId: ID; targetConversationId: ID; text: string }
  | { type: 'machine_moved'; botId: ID; sourceMachineId: ID; targetMachineId: ID };
export type ResolutionState = 'pending' | 'submitted' | 'approved' | 'denied' | 'declined' | 'expired' | 'cancelled' | 'completed' | 'failed' | 'outcome_unknown';
export interface Gate { id: ID; state: ResolutionState; targetUserId: ID; expiresAtMs: TimestampMs; resolvedAtMs: TimestampMs | null; resolvedByUserId: ID | null; revision: number }
export type ActionCategory = 'shell' | 'files' | 'external_message' | 'calendar' | 'publish' | 'purchase' | 'permissions' | 'connector' | 'handoff';
export interface Approval extends Resource { gate: Gate; entryId: ID; conversationId: ID; botId: ID; runId: ID | null; source: 'lemon_exec' | 'product'; category: ActionCategory; title: string; description: string; target: string; inputs: JSONObject; policyMode: 'ask_first' | 'auto_review' | 'allow'; review: 'not_run' | 'allow' | 'ask' | 'deny'; ruleId: ID | null; scope: ReviewScope }
export interface ApprovalResolve extends Update { decision: 'approve_once' | 'deny' }
export interface Field { id: string; label: string; kind: 'text' | 'multiline' | 'number' | 'boolean' | 'single_select' | 'multi_select'; required: boolean; options?: { value: string; label: string }[]; min?: number; max?: number }
export interface Question extends Resource { gate: Gate; entryId: ID; conversationId: ID; botId: ID; title: string; fields: Field[]; answers: Record<string, JSONValue> | null }
export interface QuestionResolve extends Update { decision: 'answer' | 'decline'; answers?: Record<string, JSONValue> }
export interface HumanStep extends Resource { gate: Gate; entryId: ID; botId: ID; conversationId: ID; machineId: ID; title: string; instructions: string; reason: 'login' | 'mfa' | 'captcha' | 'payment' | 'identity' | 'other'; externalUrl: string | null }
export interface HumanStepResolve extends Update { decision: 'done' | 'skip' }
export interface SecretRequest extends Resource { gate: Gate; entryId: ID; machineId: ID; botId: ID; name: string; description: string; scope: Secret['scope'] }
export interface SecretRequestResolve extends Update { decision: 'save' | 'decline'; value?: string }
export type DraftContent =
  | { kind: 'email'; connectorId: ID; from: string; to: string[]; cc: string[]; bcc: string[]; subject: string; body: string; attachmentIds: ID[] }
  | { kind: 'slack'; connectorId: ID; workspace: string; target: string; thread: string | null; body: string; attachmentIds: ID[] }
  | { kind: 'message'; channelBindingId: ID; target: string; thread: string | null; body: string; attachmentIds: ID[] };
export interface Draft extends Resource { entryId: ID; conversationId: ID; botId: ID; ownerUserId: ID; content: DraftContent; state: 'editable' | 'sending' | 'sent' | 'discarded' | 'failed' | 'outcome_unknown'; sendRunId: ID | null; providerMessageId: string | null; error: string | null }
export interface DraftUpdate extends Update { content: DraftContent }
export interface DraftSend extends Update { content: DraftContent }
export interface Feedback extends Resource { entryId: ID; userId: ID; sentiment: 'good' | 'bad'; reasons: ('not_requested' | 'inaccurate' | 'low_quality' | 'slow')[]; comment: string }
export interface FeedbackCreate extends Mutation { sentiment: Feedback['sentiment']; reasons?: Feedback['reasons']; comment?: string }
export interface CalendarEvent { subject: string; startAtMs: TimestampMs; endAtMs: TimestampMs; timezone: string; allDay: boolean; guests: string[]; location: string; sourceUrl: string | null; status: 'proposed' | 'confirmed' | 'cancelled' }
export type Card =
  | { type: 'text'; text: string }
  | { type: 'attachment'; attachmentId: ID; caption: string }
  | { type: 'link'; url: string; title: string; description: string }
  | { type: 'widget'; questionId: ID; prompt: string; options: { value: string; label: string }[]; multiSelect: boolean; gate: Gate }
  | { type: 'secret_request'; request: SecretRequest }
  | { type: 'human_step'; step: HumanStep }
  | { type: 'user_form'; question: Question }
  | { type: 'email_draft' | 'slack_draft' | 'message_draft'; draft: Draft }
  | { type: 'calendar_event'; event: CalendarEvent }
  | { type: 'permission_request' | 'auto_review_approval' | 'local_tool_permission' | 'publish_approval'; approval: Approval }
  | { type: 'connector'; connector: Connector }
  | { type: 'connectors'; connectors: Connector[] }
  | { type: 'listener_connect' | 'slack_connect'; channelBinding: ChannelBinding }
  | { type: 'scm_connect'; connectorId: ID; provider: string; reason: string }
  | { type: 'team_access'; botId: ID; ownerUserId: ID; reason: string; state: 'unpublished' | 'published' | 'unavailable' }
  | { type: 'bot_template_share'; templateId: ID; name: string; shareUrl: string; state: 'available' | 'deleted' | 'policy_blocked' }
  | { type: 'connector_grant'; consent: ConnectorConsent }
  | { type: 'voice_memo'; attachmentId: ID; transcript: string; durationMs: number; peaks: number[] }
  | { type: 'handoff'; targetBotId: ID; targetConversationId: ID; text: string; state: 'queued' | 'working' | 'completed' | 'failed' };
export interface ReactionRequest extends Mutation { emoji: string }
export interface Attachment extends Resource { ownerUserId: ID; conversationId: ID | null; botId: ID | null; filename: string; mime: string; size: number; sha256: string; width: number | null; height: number | null; durationMs: number | null; source: 'upload' | 'node' | 'tts' | 'generated'; state: 'ready' | 'deleted'; preview: 'image' | 'video' | 'audio' | 'pdf' | 'text' | 'markdown' | 'html' | 'json' | 'table' | 'docx' | 'download'; provenance: DeliverableProvenance }
/** Multipart metadata JSON part; file part carries original bytes. */
export interface AttachmentUpload extends Mutation { conversationId?: ID; botId?: ID; purpose: 'message' | 'avatar' | 'reference' | 'audio' }
export interface Download { url: string; expiresAtMs: TimestampMs; filename: string; mime: string; size: number }
export interface FileImport extends Mutation { path: string; conversationId?: ID; botId?: ID }
export interface Skill extends Resource { ownerUserId: ID; scope: 'personal' | 'team'; botId: ID | null; name: string; description: string; markdown: string; enabled: boolean; machineIds: ID[]; provenance: { sourceUrl: string | null; publisher: string; trusted: boolean } }
export interface SkillCreate extends Mutation { name: string; description: string; markdown: string; scope: Skill['scope']; botId?: ID; machineIds: ID[] }
export interface SkillUpdate extends Update { name?: string; description?: string; markdown?: string; enabled?: boolean; machineIds?: ID[] }
export type RoutineTrigger = { kind: 'schedule'; cron: string; timezone: string } | { kind: 'webhook' } | { kind: 'channel_event'; channelBindingId: ID; event: 'mention' | 'message' | 'reaction' | 'email_received'; channel?: string; phrase?: string; reaction?: string; senders?: string[]; noisyListenerConsent?: boolean } | { kind: 'external_event'; source: 'github' | 'linear' | 'sentry' | 'pagerduty'; eventNames: string[]; filters: JSONObject };
export interface RoutineSpec { name: string; instruction: string; trigger: RoutineTrigger; enabled: boolean }
export interface Routine extends Resource, RoutineSpec { botId: ID; ownerUserId: ID; nextRunAtMs: TimestampMs | null; scheduleDescription: string; lastRunId: ID | null; webhookUrl: string | null; cronJobId: string | null }
export interface RoutineCreate extends Mutation, RoutineSpec { botId: ID }
export interface RoutineUpdate extends Update { name?: string; instruction?: string; trigger?: RoutineTrigger; enabled?: boolean }
export interface RoutineRun extends Resource { routineId: ID; runId: ID | null; conversationId: ID; trigger: 'schedule' | 'webhook' | 'event' | 'test'; status: Run['status']; startedAtMs: TimestampMs | null; completedAtMs: TimestampMs | null; error: string | null; costUsd: number | null }
export interface WebhookKey extends Resource { routineId: ID; key: string; url: string; header: string }
export interface HookRequest { clientNonce: string; payload?: JSONValue }
export interface HookReceipt { routineRun: RoutineRun; accepted: boolean; status: 'accepted' | 'outcome_unknown' }
export interface Memory extends Resource { botId: ID; scope: 'personal' | 'team' | 'private_note'; userId: ID | null; text: string; kind: 'fact' | 'preference' | 'instruction' | 'summary'; sourceEntryId: ID | null }
export interface MemoryCreate extends Mutation { text: string; kind: Memory['kind']; scope: Memory['scope']; sourceEntryId?: ID }
export interface MemoryUpdate extends Update { text: string; kind?: Memory['kind'] }
export interface MemoryImport extends Mutation { previewId: ID; confirmationToken: string; selectedCandidateIds: ID[]; revision: number }
export interface MemoryExport { botId: ID; items: Memory[]; exportedAtMs: TimestampMs }
export type SearchHit = { kind: 'bot'; bot: Bot } | { kind: 'group'; conversation: Conversation } | { kind: 'message'; entry: TranscriptEntry; snippet: string } | { kind: 'file'; attachment: Attachment } | { kind: 'routine'; routine: Routine } | { kind: 'skill'; skill: Skill } | { kind: 'memory'; memory: Memory };
export interface SearchQuery extends PageQuery { q: string; kinds?: SearchHit['kind'][]; conversationId?: ID; botId?: ID }
export interface Notification extends Resource { userId: ID; conversationId: ID | null; botId: ID | null; entryId: ID | null; kind: 'result' | 'approval' | 'question' | 'human_step' | 'error' | 'machine'; title: string; body: string; requestId: string | null; readAtMs: TimestampMs | null; dismissedAtMs: TimestampMs | null; target: NotificationTarget; deepLink: string }
export interface NotificationUpdate extends Update { read?: boolean; dismissed?: boolean }
export interface NotificationReadAll extends Mutation { throughAtMs: TimestampMs }
export interface UsageQuery { fromAtMs: TimestampMs; toAtMs: TimestampMs; groupBy?: 'bot' | 'routine' | 'user' | 'day' | 'source'; botId?: ID; routineId?: ID }
export interface UsageBucket { key: string; inputTokens: number; outputTokens: number; requests: number; costUsd: number | null }
export interface UsageReport { fromAtMs: TimestampMs; toAtMs: TimestampMs; totals: UsageBucket; buckets: UsageBucket[]; incomplete: boolean; pricingSource: string | null }
export interface AuditRecord extends Resource { actor: Actor; action: string; resourceType: string; resourceId: ID; outcome: 'succeeded' | 'denied' | 'failed' | 'outcome_unknown'; requestId: string; metadata: JSONObject }
export interface PolicyRule extends Resource { ownerUserId: ID | null; category: ActionCategory; botId: ID | null; machineId: ID | null; mode: 'ask_first' | 'auto_review' | 'allow'; description: string; required: boolean }
export interface PolicyRuleCreate extends Mutation { category: ActionCategory; botId?: ID; machineId?: ID; mode: PolicyRule['mode']; description: string; required: boolean }
export interface PolicyRuleUpdate extends Update { mode?: PolicyRule['mode']; description?: string }
export interface Policies { revision: number; publicTemplates: boolean; allowedMcpOrigins: string[] | null; localExecutionCeiling: 'ask' | 'allow' | 'deny'; actionRecording: boolean; auditRetentionDays: number; rules: PolicyRule[] }
export interface PoliciesUpdate extends Update { publicTemplates?: boolean; allowedMcpOrigins?: string[] | null; localExecutionCeiling?: Policies['localExecutionCeiling']; actionRecording?: boolean; auditRetentionDays?: number }
export interface Connector extends Resource { botId: ID; ownerUserId: ID; name: string; url: string; accountLabel: string; authKind: 'none' | 'secret_headers' | 'oauth'; state: 'added' | 'connected' | 'needs_auth' | 'disconnected' | 'blocked' | 'failed'; tools: { name: string; enabled: boolean }[]; secretHeaderNames: string[]; shared: boolean; lastError: string | null }
export interface ConnectorCreate extends Mutation { name: string; url: string; accountLabel: string; authKind: Connector['authKind']; secretBindings?: { header: string; secretName: string }[]; shared: boolean }
export interface ConnectorUpdate extends Update { name?: string; accountLabel?: string; tools?: { name: string; enabled: boolean }[]; secretBindings?: { header: string; secretName: string }[] }
export interface ConnectorAuth extends Resource { connectorId: ID; authorizationUrl: string; expiresAtMs: TimestampMs; state: 'pending' | 'connected' | 'denied' | 'expired' | 'failed' }
export interface ConnectorConsent extends Resource { gate: Gate; connectorId: ID; accountOwnerUserId: ID; botId: ID; conversationId: ID; entryId: ID; scope: 'once' | 'bot'; expiresAtMs: TimestampMs | null }
export interface ConsentResolve extends Update { decision: 'allow_once' | 'allow_bot' | 'decline'; expiresAtMs?: TimestampMs }
export interface ChannelBinding extends Resource { botId: ID; ownerUserId: ID; adapter: 'email' | 'slack' | 'telegram' | 'discord' | 'whatsapp'; accountId: string; target: string; enabled: boolean; state: 'configured' | 'connected' | 'disconnected' | 'blocked' | 'failed'; capabilities: { events: string[]; inbound: boolean; outbound: boolean }; lastError: string | null }
export interface ChannelCreate extends Mutation { botId: ID; adapter: ChannelBinding['adapter']; accountId: string; target: string; enabled: boolean }
export interface ChannelUpdate extends Update { target?: string; enabled?: boolean }
export interface ExternalSource { source: 'github' | 'linear' | 'sentry' | 'pagerduty'; events: string[]; configured: boolean }
export interface VoiceSession extends Resource { conversationId: ID; userId: ID; deviceId: ID; settings: VoiceSettings; state: 'active' | 'ended' | 'failed'; startedAtMs: TimestampMs; endedAtMs: TimestampMs | null; durationMs: number; transcriptEntryIds: ID[]; muted: boolean; feedback: 'good' | 'bad' | null }
export interface VoiceStart extends Mutation { conversationId: ID; deviceId: ID; settings?: VoiceSettings }
export interface VoiceUpdate extends Update { muted?: boolean; settings?: VoiceSettings; feedback?: 'good' | 'bad' }
export interface TranscriptionRequest extends Mutation { attachmentId: ID; language?: string; voiceSessionId?: ID }
export interface Transcription { text: string; language: string | null; durationMs: number; segments: { text: string; startMs: number; endMs: number }[] }
export interface SpeechRequest extends Mutation { text: string; voice: VoiceSettings; conversationId?: ID; voiceSessionId?: ID }
export interface SpeechResult { attachment: Attachment; download: Download }
export interface ScopeEffect { resourceType: string; id: ID; machineId: ID | null; operation: 'delete' | 'revoke' | 'reset' | 'move' | 'retain'; explanation: string }
export interface BotPresence { botId: ID; status: 'idle' | 'working' | 'making' | 'needs_input' | 'offline'; machineId: ID; machineLabel: string; machineStatus: Machine['status']; currentRunId: ID | null; taskConversationId: ID | null; summary: string; evidenceEntryId: ID | null; measuredAtMs: TimestampMs; stale: boolean }
export type AccessLevel = 'off' | 'read_only' | 'read_interact';
export interface MachineCapability { id: string; name: string; category: 'files' | 'shell' | 'browser' | 'connector' | 'os_app'; supported: boolean; configuredLevel: AccessLevel; osGrant: 'granted' | 'denied' | 'not_required' | 'unknown'; tools: string[]; reason: string; measuredAtMs: TimestampMs; stale: boolean }
export interface MachineCapabilities { machineId: ID; os: string; measuredAtMs: TimestampMs; stale: boolean; items: MachineCapability[] }
export interface BotGrant extends Resource { botId: ID; machineId: ID; capabilityId: string; requestedLevel: AccessLevel; effectiveLevel: AccessLevel; reasons: string[] }
export interface BotGrantUpdate extends Update { requestedLevel: AccessLevel }
export interface ActivityItem extends Resource { botId: ID; machineId: ID; machineLabel: string; conversationId: ID | null; taskConversationId: ID | null; runId: ID | null; approvalId: ID | null; entryId: ID | null; kind: 'run' | 'tool' | 'approval' | 'memory' | 'preference' | 'artifact' | 'enrollment'; status: 'pending' | 'working' | 'making' | 'succeeded' | 'failed' | 'denied' | 'cancelled' | 'outcome_unknown'; title: string; summary: string; occurredAtMs: TimestampMs }
export interface ActivityQuery extends PageQuery { botId?: ID; machineId?: ID; fromAtMs?: TimestampMs; toAtMs?: TimestampMs }
export interface UpcomingItem { id: ID; kind: 'routine' | 'reminder'; botId: ID; machineId: ID; machineLabel: string; machineStatus: Machine['status']; title: string; dueAtMs: TimestampMs; timezone: string; routineId: ID | null; reminderId: ID | null; lastRunId: ID | null; lastRunStatus: Run['status'] | null; blockedReason: string | null }
export interface UpcomingQuery extends PageQuery { botId?: ID; machineId?: ID; fromAtMs?: TimestampMs; toAtMs?: TimestampMs }
export interface Reminder extends Resource { botId: ID; userId: ID; conversationId: ID; text: string; dueAtMs: TimestampMs; timezone: string; state: 'scheduled' | 'delivered' | 'cancelled' }
export interface ReminderCreate extends Mutation { botId: ID; conversationId: ID; text: string; dueAtMs: TimestampMs; timezone: string }
export interface BotOverview { bot: Bot; presence: BotPresence; machine: Machine; grants: BotGrant[]; activity: Page<ActivityItem>; upcoming: Page<UpcomingItem> }
export interface JobPreferencePatch { job?: string; instructions?: string; voice?: VoiceSettings; language?: string | null }
export interface PreferenceChange extends Resource { botId: ID; machineId: ID; userId: ID; sourceEntryId: ID | null; scope: 'job' | 'voice' | 'language'; before: JobPreferencePatch; after: JobPreferencePatch; reason: string; resultingBotRevision: number; state: 'applied' | 'undone'; undoneAtMs: TimestampMs | null }
export interface PreferenceChangeCreate extends Update { changes: JobPreferencePatch; reason: string; sourceEntryId?: ID }
export interface PreferenceUndo extends Update { botRevision: number }
export type BotResetScope = 'conversations' | 'memory' | 'job' | 'routines' | 'connectors' | 'attachments';
export interface BotReset extends Confirm { resetScopes: BotResetScope[] }
export interface BotResetResult { bot: Bot; removedIds: ID[]; retainedScopes: BotResetScope[]; status: 'completed' | 'outcome_unknown' }
export interface MemoryImportPreviewRequest extends Mutation { scope: Memory['scope']; text?: string; attachmentId?: ID; format: 'facts_text' | 'lemon_memory_json' | 'chat_export_zip' }
export interface MemoryImportCandidate { id: ID; text: string; kind: Memory['kind']; source: { filename: string | null; locator: string; excerpt: string }; selectedByDefault: boolean }
export interface MemoryImportPreview extends Resource { botId: ID; machineId: ID; userId: ID; scope: Memory['scope']; sourceSha256: string; candidates: MemoryImportCandidate[]; exclusions: { locator: string; reason: 'credential' | 'private_profile' | 'unsupported' | 'duplicate' | 'not_durable'; summary: string }[]; confirmationToken: string; expiresAtMs: TimestampMs }
export interface MemoryImportResult { previewId: ID; items: Memory[]; status: 'completed' | 'outcome_unknown'; failedCandidateIds: ID[] }
export interface BotIdea { id: string; botId: ID; title: string; prompt: string; expectedOutput: string; requiredSkillIds: ID[]; requiredConnectorIds: ID[]; requiredCapabilityIds: string[]; ready: boolean; blockedReasons: string[] }
export interface DeliverableProvenance { botId: ID | null; runId: ID | null; machineId: ID | null; sourceEntryId: ID | null; generatedAtMs: TimestampMs | null }
export interface ReviewScope { kind: 'once' | 'run' | 'site' | 'connector'; label: string; machineId: ID; machineLabel: string; botId: ID; runId: ID | null; origin: string | null; connectorId: ID | null; consequences: string[]; expiresAtMs: TimestampMs }
export type NotificationTarget = { kind: 'entry'; botId: ID; conversationId: ID; taskConversationId: ID | null; entryId: ID } | { kind: 'approval'; botId: ID; conversationId: ID; approvalId: ID; entryId: ID } | { kind: 'machine'; machineId: ID; botId: ID | null } | { kind: 'routine'; botId: ID; routineId: ID; routineRunId: ID | null };
export interface Milestone extends Resource { botId: ID; userId: ID; kind: 'machine_attached' | 'first_routine_success' | 'first_approved_task_completed'; evidenceId: ID; earnedAtMs: TimestampMs; acknowledgedAtMs: TimestampMs | null }
export interface VoicePreviewRequest extends Mutation { voice?: VoiceSettings }
export interface ClientLocalSettings { summonShortcut: string | null; pushToTalkShortcut: string | null; micCuesEnabled: boolean; selectedBotId: ID | null; compactCompanionEnabled: boolean; reducedMotion: 'system' | 'on' | 'off' }
export interface ConnectorSetupRequest extends Mutation { machineId: ID; name: string; url: string; accountLabel: string; shared: boolean; authKind: Connector['authKind']; secretBindings: { header: string; secretName: string }[]; requestedLevel: AccessLevel }
export interface ConnectorSetupResult { connector: Connector; machineId: ID; secretNames: string[]; grants: BotGrant[] }
export interface Snapshot { cursor: Cursor; user: User; workspace: Workspace; member: Member; capabilities: Capabilities; bots: Bot[]; machines: Machine[]; conversations: Conversation[]; sections: Section[]; notifications: Notification[]; activeRuns: Run[]; hasMore: { bots: boolean; machines: boolean; conversations: boolean; notifications: boolean } }
export type ResourceEventPayloads = {
  'user.updated': User; 'workspace.updated': Workspace; 'member.upserted': Member; 'member.deleted': Deleted; 'invite.upserted': MemberInvite; 'device.upserted': Device; 'device.deleted': Deleted;
  'machine.upserted': Machine; 'machine.deleted': Deleted; 'machine_invite.upserted': MachineInvite;
  'bot.upserted': Bot; 'bot.deleted': Deleted; 'section.upserted': Section; 'section.deleted': Deleted; 'template.upserted': BotTemplate; 'template.deleted': Deleted;
  'conversation.upserted': Conversation; 'conversation.deleted': Deleted; 'conversation.read': { conversationId: ID; userId: ID; throughSeq: number; unread: boolean }; 'composer.updated': ComposerDraft;
  'entry.upserted': TranscriptEntry; 'entry.deleted': { id: ID; conversationId: ID }; 'entry.delta': { conversationId: ID; entryId: ID; runId: ID; offset: number; text: string }; 'run.upserted': Run;
  'attachment.upserted': Attachment; 'attachment.deleted': Deleted; 'approval.upserted': Approval; 'question.upserted': Question; 'human_step.upserted': HumanStep; 'secret_request.upserted': SecretRequest; 'draft.upserted': Draft;
  'skill.upserted': Skill; 'skill.deleted': Deleted; 'routine.upserted': Routine; 'routine.deleted': Deleted; 'routine_run.upserted': RoutineRun; 'memory.upserted': Memory; 'memory.deleted': { id: ID; botId: ID; scope: Memory['scope']; userId: ID | null };
  'notification.upserted': Notification; 'notification.deleted': Deleted; 'policies.updated': Policies; 'connector.upserted': Connector; 'connector.deleted': Deleted; 'connector_auth.upserted': ConnectorAuth; 'consent.upserted': ConnectorConsent; 'channel.upserted': ChannelBinding; 'channel.deleted': Deleted; 'voice.upserted': VoiceSession;
  'bot.presence': BotPresence; 'grant.upserted': BotGrant; 'activity.upserted': ActivityItem; 'reminder.upserted': Reminder; 'reminder.deleted': Deleted; 'preference_change.upserted': PreferenceChange; 'milestone.upserted': Milestone;
  'directory_group.upserted': DirectoryGroup; 'directory_group.deleted': Deleted; 'group_policy.upserted': GroupPolicy; 'governance.updated': Governance;
  'network_policy.upserted': NetworkPolicy; 'network_policy.deleted': Deleted; 'policy_application.upserted': PolicyApplication; 'egress.upserted': EgressRoute;
  'setup_manifest.upserted': SetupManifest; 'setup_run.upserted': SetupRun; 'host_operation.upserted': HostOperation; 'spend_limit.upserted': SpendLimit;
  'export.upserted': ExportRecord; 'channel_setup.upserted': ChannelSetupFlow; 'email_account.upserted': EmailAccount; 'x_connection.upserted': XConnection;
};
export type RealtimeEvent = { [K in keyof ResourceEventPayloads]: { type: 'event'; seq: Cursor; event: K; payload: ResourceEventPayloads[K]; timestampMs: TimestampMs } }[keyof ResourceEventPayloads];
export type RealtimeClientFrame =
  | { type: 'auth'; token: string; deviceId?: ID }
  | { type: 'subscribe'; requestId: string; cursor?: Cursor; conversationIds?: ID[] }
  | { type: 'ack'; cursor: Cursor }
  | { type: 'ping'; requestId: string }
  | { type: 'typing'; conversationId: ID; active: boolean }
  | { type: 'presence'; foreground: boolean; conversationId: ID | null }
  | { type: 'terminal_subscribe'; terminalId: ID; afterSeq?: number }
  | { type: 'voice'; voiceSessionId: ID; action: 'mute' | 'unmute' | 'end' };
export type RealtimeServerFrame = RealtimeEvent
  | { type: 'ready'; userId: ID; workspaceId: ID; cursor: Cursor; earliestCursor: Cursor; heartbeatMs: number }
  | { type: 'subscribed'; requestId: string; cursor: Cursor; conversationIds: ID[] }
  | { type: 'caught_up'; cursor: Cursor }
  | { type: 'watermark'; cursor: Cursor }
  | { type: 'pong'; requestId: string }
  | { type: 'error'; requestId?: string; error: ErrorEnvelope['error'] }
  | { type: 'typing'; conversationId: ID; userId: ID; active: boolean; expiresAtMs: TimestampMs }
  | { type: 'terminal_output'; terminalId: ID; seq: number; dataBase64: string }
  | { type: 'terminal_exit'; terminalId: ID; code: number | null }
  | { type: 'terminal_gap'; terminalId: ID; earliestSeq: number; latestSeq: number };
/** Local open/play/preview/copy never resolve gates; these are the persisted client actions. */
export type CardAction =
  | { action: 'answer'; questionId: ID; request: QuestionResolve }
  | { action: 'approve' | 'deny'; approvalId: ID; request: ApprovalResolve }
  | { action: 'human_done' | 'human_skip'; humanStepId: ID; request: HumanStepResolve }
  | { action: 'secret_save' | 'secret_decline'; secretRequestId: ID; request: SecretRequestResolve }
  | { action: 'draft_edit'; draftId: ID; request: DraftUpdate }
  | { action: 'draft_send'; draftId: ID; request: DraftSend }
  | { action: 'draft_discard'; draftId: ID; request: Update }
  | { action: 'connector_authorize'; connectorId: ID; request: Mutation }
  | { action: 'connector_consent'; consentId: ID; request: ConsentResolve }
  | { action: 'template_import'; templateId: ID; request: TemplateImport }
  | { action: 'team_publish'; botId: ID; request: BotUpdate };
export interface PushPayload { version: 1; notificationId: ID; workspaceId: ID; conversationId: ID | null; entryId: ID | null; title: string; body: string; target: NotificationTarget; deepLink: string }
/** Bot token identifies bot; conversationId selects only a verified active invocation context. */
export interface ToolContextInput extends Mutation { conversationId?: ID }
export interface MessageBotInput extends ToolContextInput { targetBotId: ID; text: string; attachmentIds?: ID[]; replyConversationId?: ID }
export interface HandoffInput extends MessageBotInput { task: string }
export interface DraftToolInput extends ToolContextInput { content: DraftContent }
export interface AskUserInput extends ToolContextInput { title: string; fields: Field[]; expiresInMs?: number }
export interface ApprovalToolInput extends ToolContextInput { category: ActionCategory; title: string; description: string; target: string; inputs: JSONObject; expiresInMs?: number }
export interface HumanStepInput extends ToolContextInput { title: string; instructions: string; reason: HumanStep['reason']; externalUrl?: string; expiresInMs?: number }
export interface SecretToolInput extends ToolContextInput { name: string; description: string; scope: Secret['scope']; expiresInMs?: number }
export interface VoiceMemoInput extends ToolContextInput { text: string; voice?: VoiceSettings }
export interface ShareFileInput extends ToolContextInput { path: string; filename?: string; caption?: string }
export interface PostGroupInput extends Mutation { groupConversationId: ID; text: string; attachmentIds?: ID[]; mentions?: ID[] }
export interface BotListInput { query?: string; limit?: number; cursor?: Cursor }
export interface RememberInput extends ToolContextInput { text: string; kind: Memory['kind']; scope: Memory['scope'] }
export interface PreferenceToolInput extends ToolContextInput { revision: number; changes: JobPreferencePatch; reason: string; sourceEntryId: ID }
export interface ReminderToolInput extends ToolContextInput { text: string; dueAtMs: TimestampMs; timezone: string }
export interface ToolEntryResult { entry: TranscriptEntry }
export interface MessageBotResult { receipt: MessageReceipt; conversationId: ID }
export interface QuestionToolResult { question: Question; state: ResolutionState; answers: Record<string, JSONValue> | null }
export interface ApprovalToolResult { approval: Approval; decision: 'approved' | 'denied' | 'expired' | 'cancelled' }
export interface HumanStepToolResult { step: HumanStep; decision: 'done' | 'skipped' | 'expired' | 'cancelled' }
export interface SecretToolResult { request: SecretRequest; saved: boolean; name: string }
export interface MCPToolInputs { message_bot: MessageBotInput; handoff: HandoffInput; create_draft: DraftToolInput; ask_user: AskUserInput; request_approval: ApprovalToolInput; request_human_step: HumanStepInput; request_secret: SecretToolInput; send_voice_memo: VoiceMemoInput; share_file: ShareFileInput; create_routine: Omit<RoutineCreate, 'botId'>; update_routine: RoutineUpdate & { routineId: ID }; save_skill: Omit<SkillCreate, 'machineIds' | 'botId'>; list_bots: BotListInput; post_to_group: PostGroupInput; remember: RememberInput; create_bot: BotCreate; update_preferences: PreferenceToolInput; create_reminder: ReminderToolInput }
export interface MCPToolResults { message_bot: MessageBotResult; handoff: MessageBotResult; create_draft: Draft; ask_user: QuestionToolResult; request_approval: ApprovalToolResult; request_human_step: HumanStepToolResult; request_secret: SecretToolResult; send_voice_memo: ToolEntryResult; share_file: ToolEntryResult; create_routine: Routine; update_routine: Routine; save_skill: Skill; list_bots: Page<Bot>; post_to_group: MessageReceipt; remember: Memory; create_bot: Bot; update_preferences: PreferenceChange; create_reminder: Reminder }
export interface MCPToolSchema { name: keyof MCPToolInputs; description: string; inputSchema: JSONObject }
export interface MCPCallResult<T> { content: { type: 'text'; text: string }[]; structuredContent: T; isError?: boolean }
export type Endpoint<Request, Response, Query = undefined> = { request: Request; response: Response; query: Query };
export interface OIDCProvider extends Resource { name: string; issuer: string; clientId: string; scopes: string[]; allowedEmailDomains: string[]; enabled: boolean; requireSSO: boolean; groupClaim: string | null; clientSecretRef: string; endSessionEndpoint: string | null }
export interface OIDCProviderCreate extends Mutation { name: string; issuer: string; clientId: string; scopes: string[]; allowedEmailDomains: string[]; clientSecretRef: string; groupClaim?: string; requireSSO: boolean }
export interface OIDCProviderUpdate extends Update { enabled?: boolean; requireSSO?: boolean; allowedEmailDomains?: string[]; scopes?: string[] }
export interface OIDCStart extends Mutation { providerId: ID; redirectUri: string; codeChallenge: string; purpose: 'login' | 'reauth' | 'link'; deviceId?: ID }
export interface OIDCFlow { id: ID; authorizationUrl: string; expiresAtMs: TimestampMs }
export interface OIDCComplete extends Mutation { flowId: ID; completionCode: string; codeVerifier: string; deviceId?: ID }
export interface IdentityLink extends Resource { userId: ID; providerId: ID; issuer: string; subject: string; lastUsedAtMs: TimestampMs | null }
export interface OIDCLinkRequest extends OIDCComplete { reauthToken: string }
export interface IdentityUnlink extends Update { reauthToken: string }
export interface RedirectResponse { status: 302; location: string }
export interface DirectoryGroup extends Resource { name: string; externalId: string | null; source: 'local' | 'oidc' | 'scim'; memberUserIds: ID[] }
export interface DirectoryGroupCreate extends Mutation { name: string; memberUserIds: ID[] }
export interface DirectoryGroupUpdate extends Update { name?: string; memberUserIds?: ID[] }
export interface GroupPolicy extends Resource { directoryGroupId: ID; productAccess: boolean; defaultBotIds: ID[]; capabilityModes: Partial<Record<ActionCategory, 'ask_first' | 'auto_review' | 'allow'>>; requiredRuleIds: ID[]; localExecutionCeiling: 'deny' | 'ask' | 'allow'; allowEgress: boolean; allowSudo: boolean; networkPolicyId: ID | null; reviewExempt: boolean }
export interface GroupPolicyUpdate extends Update { productAccess?: boolean; defaultBotIds?: ID[]; capabilityModes?: GroupPolicy['capabilityModes']; requiredRuleIds?: ID[]; localExecutionCeiling?: GroupPolicy['localExecutionCeiling']; allowEgress?: boolean; allowSudo?: boolean; networkPolicyId?: ID | null; reviewExempt?: boolean }
export interface Governance { revision: number; groupAccess: 'all' | 'selected'; allowedDirectoryGroupIds: ID[]; allowSudo: boolean; allowEgress: boolean; lockNetworkForGroups: boolean; requireReview: boolean; allowedChannelAdapters: ChannelBinding['adapter'][]; xMentionsEnabled: boolean; emailEnabled: boolean; contentExportEnabled: boolean; inactiveHostPolicy: { enabled: boolean; afterDays: number; action: 'suspend' | 'stop_worker' } }
export interface GovernanceUpdate extends Update { groupAccess?: Governance['groupAccess']; allowedDirectoryGroupIds?: ID[]; allowSudo?: boolean; allowEgress?: boolean; lockNetworkForGroups?: boolean; requireReview?: boolean; allowedChannelAdapters?: ChannelBinding['adapter'][]; xMentionsEnabled?: boolean; emailEnabled?: boolean; contentExportEnabled?: boolean; inactiveHostPolicy?: Governance['inactiveHostPolicy'] }
export interface NetworkRule { kind: 'domain' | 'ip_cidr'; value: string; ports: number[]; protocol: 'tcp' | 'udp' | 'both' }
export interface NetworkPolicy extends Resource { scope: 'workspace' | 'directory_group'; directoryGroupId: ID | null; mode: 'allow_all' | 'defaults_plus_allowlist' | 'allowlist_only'; rules: NetworkRule[]; requiredRuntimeDestinations: NetworkRule[] }
export interface NetworkPolicyCreate extends Mutation { scope: NetworkPolicy['scope']; directoryGroupId?: ID; mode: NetworkPolicy['mode']; rules: NetworkRule[] }
export interface NetworkPolicyUpdate extends Update { mode?: NetworkPolicy['mode']; rules?: NetworkRule[] }
export interface PolicyApplication { machineId: ID; desiredRevision: number; appliedRevision: number | null; state: 'pending' | 'applied' | 'failed' | 'offline' | 'unsupported'; error: string | null; measuredAtMs: TimestampMs }
export interface EffectivePolicy { userId: ID; botId: ID | null; directoryGroupIds: ID[]; productAccess: boolean; localExecutionCeiling: GroupPolicy['localExecutionCeiling']; allowSudo: boolean; allowEgress: boolean; rules: PolicyRule[]; networkPolicies: NetworkPolicy[]; explanations: string[] }
export interface EgressRoute extends Resource { machineId: ID; ownerUserId: ID; throughMachineId: ID; state: 'connecting' | 'active' | 'disabled' | 'failed'; enabled: boolean; rememberedPreference: boolean; error: string | null }
export interface EgressRouteCreate extends Mutation { machineId: ID; throughMachineId: ID; enabled: boolean }
export interface EgressRouteUpdate extends Update { enabled: boolean }
export interface SetupManifest extends Resource { name: string; directoryGroupId: ID | null; machineIds: ID[]; entries: { id: string; setupScript: string; checkScript: string | null; secretNames: string[]; timeoutMs: number }[]; enabled: boolean }
export interface SetupManifestCreate extends Mutation { name: string; directoryGroupId?: ID; machineIds: ID[]; entries: SetupManifest['entries']; enabled: boolean }
export interface SetupManifestUpdate extends Update { entries?: SetupManifest['entries']; enabled?: boolean; machineIds?: ID[] }
export interface SetupRun extends Resource { manifestId: ID; machineId: ID; state: 'queued' | 'running' | 'succeeded' | 'failed' | 'skipped' | 'outcome_unknown'; entryResults: { entryId: string; state: 'pending' | 'skipped' | 'succeeded' | 'failed'; exitCode: number | null; summary: string }[] }
export type HostAction = 'update' | 'recover' | 'restart_worker' | 'stop_worker' | 'suspend' | 'recreate_environment' | 'delete_environment';
export interface HostOperationPreview extends Mutation { machineIds: ID[]; action: HostAction }
export interface HostOperationCreate extends Confirm { machineIds: ID[]; action: HostAction }
export interface HostOperation extends Resource { action: HostAction; ownerUserId: ID; state: 'queued' | 'running' | 'completed' | 'failed' | 'outcome_unknown'; results: { machineId: ID; state: 'queued' | 'running' | 'succeeded' | 'skipped' | 'failed' | 'outcome_unknown'; reason: string | null }[] }
export interface HostManagement { machineId: ID; supportedActions: HostAction[]; provider: 'systemd' | 'launchd' | 'container' | 'custom'; supportsNetworkPolicy: boolean; supportsEgress: boolean; supportsSetup: boolean; lastBackupAtMs: TimestampMs | null; environmentRoot: string | null }
export interface SpendLimit extends Resource { scope: 'workspace' | 'user' | 'bot' | 'routine'; subjectId: ID | null; period: 'day' | 'week' | 'month'; limitUsd: number; warningPercent: number; enabled: boolean; enforcement: 'block_new_runs'; providerAccount: string | null }
export interface SpendLimitCreate extends Mutation { scope: SpendLimit['scope']; subjectId?: ID; period: SpendLimit['period']; limitUsd: number; warningPercent: number; providerAccount?: string }
export interface SpendLimitUpdate extends Update { limitUsd?: number; warningPercent?: number; enabled?: boolean }
export interface SpendStatus { limit: SpendLimit; spentUsd: number | null; remainingUsd: number | null; resetsAtMs: TimestampMs; state: 'ok' | 'warning' | 'exhausted' | 'unknown' }
export interface ExportDestination extends Resource { name: string; url: string; protocol: 'otlp_http' | 'ndjson_webhook'; secretRef: string | null; streams: ('audit' | 'action' | 'usage' | 'conversation_content')[]; enabled: boolean }
export interface ExportDestinationCreate extends Mutation { name: string; url: string; protocol: ExportDestination['protocol']; secretRef?: string; streams: ExportDestination['streams']; enabled: boolean }
export interface ExportDestinationUpdate extends Update { enabled?: boolean; streams?: ExportDestination['streams'] }
export interface AuditExportCreate extends Mutation { fromAtMs: TimestampMs; toAtMs: TimestampMs; kind: 'audit' | 'action' | 'usage' | 'conversation_content'; conversationIds?: ID[] }
export interface ExportRecord extends Resource { destinationId: ID | null; fromAtMs: TimestampMs; toAtMs: TimestampMs; kind: AuditExportCreate['kind']; state: 'queued' | 'running' | 'completed' | 'failed'; attachmentId: ID | null; lastDeliveredCursor: Cursor | null; error: string | null }
export interface ChannelSetup extends Mutation { botId: ID; adapter: ChannelBinding['adapter']; providerId: string; accountLabel: string; redirectUri: string }
export interface ChannelSetupFlow extends Resource { botId: ID; adapter: ChannelBinding['adapter']; authorizationUrl: string | null; state: 'pending' | 'awaiting_admin' | 'connected' | 'denied' | 'failed'; channelBindingId: ID | null; error: string | null }
export interface ChannelPrincipalLink extends Resource { channelBindingId: ID; externalUserId: string; userId: ID; verified: boolean }
export interface ChannelLinkCreate extends Mutation { channelBindingId: ID; externalUserId: string; verificationCode: string }
export interface ChannelLinkStart extends Mutation { channelBindingId: ID }
export interface ChannelLinkFlow extends Resource { userId: ID; channelBindingId: ID; state: 'issued' | 'awaiting_external' | 'verified' | 'completed' | 'expired' | 'cancelled'; linkCode: string | null; instructions: string; externalUserId: string | null; externalDisplayName: string | null; verificationCode: string | null; expiresAtMs: TimestampMs }
export interface EmailAccount extends Resource { userId: ID; provider: string; address: string; immutableAddress: boolean; state: 'pending' | 'active' | 'disabled' | 'retired'; channelBindingId: ID | null; indexingDelayed?: boolean | null; indexingMeasuredAtMs?: TimestampMs | null }
export interface EmailAddressCheck extends Mutation { providerId: string; localPart: string }
export interface EmailAddressAvailability { providerId: string; address: string; available: boolean; reason: string | null; immutable: boolean }
export interface EmailAddressClaim extends Mutation { providerId: string; localPart: string; approvalId: ID }
export interface EmailAddressProposal extends EmailAddressCheck { botId: ID }
export interface ContentExportConsent extends Resource { conversationId: ID; userId: ID; enabled: boolean }
export interface ContentExportConsentUpdate extends Update { enabled: boolean }
export interface EmailMessage extends Resource { accountId: ID; from: string; to: string[]; subject: string; receivedAtMs: TimestampMs; authentication: 'passed' | 'failed' | 'unknown'; scan: 'passed' | 'spam' | 'virus' | 'pending'; text: string | null; attachmentIds: ID[]; skippedAttachmentNames: string[] }
export interface XConnection extends Resource { userId: ID; externalAccountId: string; username: string; mainBotId: ID; enabled: boolean; state: 'pending' | 'connected' | 'needs_auth' | 'blocked' | 'failed'; lastError: string | null }
export interface XConnect extends Mutation { mainBotId: ID; redirectUri: string }
export interface XConnectResult { connection: XConnection; authorizationUrl: string }
export interface XConnectionUpdate extends Update { mainBotId?: ID; enabled?: boolean }
export interface XIngress { deliveryId: string; externalAccountId: string; mentionPostId: string; mentionedHandle: string; text: string; repliedPost?: JSONObject; quotedPosts?: JSONObject[]; mediaAttachmentIds?: ID[] }
export interface IntegrationIngressReceipt { accepted: boolean; status: 'accepted' | 'ignored' | 'outcome_unknown'; reason: string | null; runId: ID | null; conversationId: ID | null }
export interface IntegrationWebhook { deliveryId: string; event: string; payload: JSONObject }
export interface IntegrationToken extends Resource { name: string; kind: 'scim' | 'event_ingress' | 'audit_export'; scopes: string[]; expiresAtMs: TimestampMs | null }
export interface IntegrationTokenCreate extends Mutation { name: string; kind: IntegrationToken['kind']; scopes: string[]; expiresInMs?: number }
export interface IntegrationTokenIssued { integration: IntegrationToken; token: string }
export interface SCIMMeta { resourceType: 'User' | 'Group'; created: string; lastModified: string; location: string; version: string }
export interface SCIMUser { schemas: string[]; id: ID; externalId?: string; userName: string; name?: { givenName?: string; familyName?: string; formatted?: string }; displayName?: string; active: boolean; emails?: { value: string; primary?: boolean; type?: string }[]; groups?: { value: ID; display?: string }[]; meta: SCIMMeta }
export type SCIMUserInput = Omit<SCIMUser, 'id' | 'meta' | 'groups'>;
export interface SCIMGroup { schemas: string[]; id: ID; externalId?: string; displayName: string; members: { value: ID; display?: string }[]; meta: SCIMMeta }
export type SCIMGroupInput = Omit<SCIMGroup, 'id' | 'meta'>;
export interface SCIMPatch { schemas: string[]; Operations: { op: 'add' | 'remove' | 'replace'; path?: string; value?: JSONValue }[] }
export interface SCIMQuery { startIndex?: number; count?: number; filter?: string; attributes?: string; excludedAttributes?: string }
export interface SCIMList<T> { schemas: string[]; totalResults: number; startIndex: number; itemsPerPage: number; Resources: T[] }
export interface SCIMError { schemas: string[]; status: string; scimType?: string; detail: string }
export interface SCIMServiceProviderConfig { schemas: string[]; patch: { supported: true }; bulk: { supported: false; maxOperations: 0; maxPayloadSize: 0 }; filter: { supported: true; maxResults: 200 }; changePassword: { supported: false }; sort: { supported: false }; etag: { supported: true }; authenticationSchemes: { type: 'oauthbearertoken'; name: string; description: string; primary: true }[] }
export interface SCIMResourceType { schemas: string[]; id: string; name: string; endpoint: string; schema: string }
export interface SCIMSchema { schemas: string[]; id: string; name: string; description: string; attributes: JSONObject[] }
/** Private operator configuration; never returned through product REST or model tools. */
export type ServerSecretSource = { kind: 'env'; name: string } | { kind: 'file'; path: string };
export interface OAuthProviderConfig { id: string; clientId: string; clientSecretRef: string; authorizeUrl: string; tokenUrl: string; scopes: string[]; redirectUris: string[]; allowedOrigins: string[] }
export interface ChannelProviderConfig { id: string; adapter: ChannelBinding['adapter']; oauth: OAuthProviderConfig | null; signingSecretRef: string | null; apiBaseUrl: string; accountSecretRef: string | null; capabilities: ChannelBinding['capabilities']; supportsBotAppInstall: boolean }
export interface EmailProviderConfig { id: string; domain: string; provisioningBaseUrl: string; provisioningSecretRef: string; immutableAddresses: boolean; reservedNames: string[]; smtp: { host: string; port: number; tls: true; secretRef: string }; imap: { host: string; port: number; tls: true; secretRef: string }; signingSecretRef: string; supportsUnsubscribe: boolean }
export interface EventProviderConfig { id: string; source: ExternalSource['source'] | 'slack' | 'email'; signingSecretRef: string; eventNames: string[]; routineIds: ID[]; principalUserId: ID; maxAgeMs: number; eventDefinitions?: EventDefinition[] }
export interface HostDriverCommand { argv: string[]; cwd: string; timeoutMs: number; probeArgv: string[] }
export interface HostDriverConfig { machineId: ID; provider: HostManagement['provider']; environmentRoot: string | null; actions: Partial<Record<HostAction, HostDriverCommand>>; networkApply: HostDriverCommand | null; egressApply: HostDriverCommand | null; setupRun: HostDriverCommand | null; runtimeDestinations: NetworkRule[] }
export interface ConnectorProviderConfig { id: string; origins: string[]; oauth: OAuthProviderConfig | null; sharedServiceAccount: boolean }
export interface ReviewedSetupManifest { name: string; directoryGroupId: ID | null; machineIds: ID[]; entries: SetupManifest['entries'] }
export interface IntegrationProvider { id: string; kind: 'connector' | 'channel' | 'email' | 'x' | 'event' | 'identity' | 'export' | 'host'; label: string; configured: boolean; prerequisites: string[]; capabilities: string[] }
export interface ChannelProviderInfo extends IntegrationProvider { kind: 'channel'; adapter: ChannelBinding['adapter']; supportsBotAppInstall: boolean }
export interface EmailProviderInfo extends IntegrationProvider { kind: 'email'; domain: string; immutableAddresses: boolean; supportsProvisioning: boolean; supportsUnsubscribe: boolean }
export interface XProviderInfo extends IntegrationProvider { kind: 'x'; publicHandle: string; oauthScopes: string[]; allowedMedia: ('photo' | 'video' | 'gif')[]; deniedCountries: string[] }
export interface EventDefinition { name: string; label: string; description: string; filterSchema: JSONObject }
export interface ExternalSourceDefinition { source: ExternalSource['source']; configured: boolean; events: EventDefinition[] }
export interface OperatorConfiguration { version: 1; trustedFrontendOrigins: string[]; oauthRedirectUris: string[]; serverSecrets: Record<string, ServerSecretSource>; channelProviders: ChannelProviderConfig[]; emailProviders: EmailProviderConfig[]; eventProviders: EventProviderConfig[]; hostDrivers: HostDriverConfig[]; xProvider: { oauth: OAuthProviderConfig; publicHandle: string; signingSecretRef: string; apiBaseUrl: string; deniedCountries: string[]; allowedMedia: ('photo' | 'video' | 'gif')[] } | null; exportAllowedOrigins: string[]; requiredRuntimeDestinations: NetworkRule[]; breakGlassOwnerUserId: ID | null; connectorProviders?: ConnectorProviderConfig[]; approvedPrivateMcpOrigins?: string[]; reviewedSetupManifests?: ReviewedSetupManifest[] }
/** Canonical method+path keys. Undefined means no JSON body/query, never an empty JSON object. */
export interface RestEndpoints {
  'GET /integration-providers': Endpoint<undefined, IntegrationProvider[]>;
  'GET /channels/providers': Endpoint<undefined, ChannelProviderInfo[]>;
  'GET /email/providers': Endpoint<undefined, EmailProviderInfo[]>;
  'GET /x/provider': Endpoint<undefined, XProviderInfo | null>;
  'POST /channels/principal-links/start': Endpoint<ChannelLinkStart, ChannelLinkFlow>;
  'GET /channels/principal-links/flows/:id': Endpoint<undefined, ChannelLinkFlow>;
  'GET /event-sources/:source': Endpoint<undefined, ExternalSourceDefinition>;
  'GET /auth/identities': Endpoint<undefined, Page<IdentityLink>, PageQuery>;
  'POST /auth/oidc/link': Endpoint<OIDCLinkRequest, IdentityLink>;
  'DELETE /auth/identities/:id': Endpoint<IdentityUnlink, Deleted>;
  'POST /email/address/approval': Endpoint<EmailAddressProposal, Approval>;
  'GET /scim/v2/ResourceTypes/:id': Endpoint<undefined, SCIMResourceType>;
  'GET /scim/v2/Schemas/:id': Endpoint<undefined, SCIMSchema>;
  'GET /conversations/:id/export-consent': Endpoint<undefined, ContentExportConsent>;
  'PUT /conversations/:id/export-consent': Endpoint<ContentExportConsentUpdate, ContentExportConsent>;
  'GET /auth/oidc/providers': Endpoint<undefined, { id: ID; name: string; enabled: boolean; requireSSO: boolean }[]>;
  'POST /auth/oidc/start': Endpoint<OIDCStart, OIDCFlow>;
  'GET /auth/oidc/callback/:providerId': Endpoint<undefined, RedirectResponse, OAuthCallbackQuery>;
  'POST /auth/oidc/complete': Endpoint<OIDCComplete, AuthResult | ReauthResult>;
  'GET /admin/oidc/providers': Endpoint<undefined, Page<OIDCProvider>, PageQuery>;
  'POST /admin/oidc/providers': Endpoint<OIDCProviderCreate, OIDCProvider>;
  'PATCH /admin/oidc/providers/:id': Endpoint<OIDCProviderUpdate, OIDCProvider>;
  'DELETE /admin/oidc/providers/:id': Endpoint<Update, Deleted>;
  'GET /directory/groups': Endpoint<undefined, Page<DirectoryGroup>, PageQuery>;
  'POST /directory/groups': Endpoint<DirectoryGroupCreate, DirectoryGroup>;
  'PATCH /directory/groups/:id': Endpoint<DirectoryGroupUpdate, DirectoryGroup>;
  'DELETE /directory/groups/:id': Endpoint<Update, Deleted>;
  'GET /directory/groups/:id/policy': Endpoint<undefined, GroupPolicy>;
  'PATCH /directory/groups/:id/policy': Endpoint<GroupPolicyUpdate, GroupPolicy>;
  'GET /governance': Endpoint<undefined, Governance>;
  'PATCH /governance': Endpoint<GovernanceUpdate, Governance>;
  'GET /policies/effective': Endpoint<undefined, EffectivePolicy, { userId?: ID; botId?: ID }>;
  'GET /network-policies': Endpoint<undefined, Page<NetworkPolicy>, PageQuery>;
  'POST /network-policies': Endpoint<NetworkPolicyCreate, NetworkPolicy>;
  'PATCH /network-policies/:id': Endpoint<NetworkPolicyUpdate, NetworkPolicy>;
  'DELETE /network-policies/:id': Endpoint<Update, Deleted>;
  'GET /network-policies/:id/applications': Endpoint<undefined, Page<PolicyApplication>, PageQuery>;
  'POST /network-policies/:id/apply': Endpoint<Mutation & { machineIds: ID[] }, Page<PolicyApplication>>;
  'GET /egress-routes': Endpoint<undefined, Page<EgressRoute>, PageQuery>;
  'POST /egress-routes': Endpoint<EgressRouteCreate, EgressRoute>;
  'PATCH /egress-routes/:id': Endpoint<EgressRouteUpdate, EgressRoute>;
  'DELETE /egress-routes/:id': Endpoint<Update, Deleted>;
  'GET /setup-manifests': Endpoint<undefined, Page<SetupManifest>, PageQuery>;
  'POST /setup-manifests': Endpoint<SetupManifestCreate, SetupManifest>;
  'PATCH /setup-manifests/:id': Endpoint<SetupManifestUpdate, SetupManifest>;
  'DELETE /setup-manifests/:id': Endpoint<Update, Deleted>;
  'POST /setup-manifests/:id/run': Endpoint<Mutation & { machineIds: ID[] }, Page<SetupRun>>;
  'GET /setup-runs': Endpoint<undefined, Page<SetupRun>, PageQuery & { manifestId?: ID; machineId?: ID }>;
  'GET /machines/:id/management': Endpoint<undefined, HostManagement>;
  'POST /host-operations/preview': Endpoint<HostOperationPreview, Confirmation>;
  'POST /host-operations': Endpoint<HostOperationCreate, HostOperation>;
  'GET /host-operations': Endpoint<undefined, Page<HostOperation>, PageQuery>;
  'GET /host-operations/:id': Endpoint<undefined, HostOperation>;
  'GET /spend-limits': Endpoint<undefined, Page<SpendStatus>, PageQuery>;
  'POST /spend-limits': Endpoint<SpendLimitCreate, SpendLimit>;
  'PATCH /spend-limits/:id': Endpoint<SpendLimitUpdate, SpendLimit>;
  'DELETE /spend-limits/:id': Endpoint<Update, Deleted>;
  'GET /export-destinations': Endpoint<undefined, Page<ExportDestination>, PageQuery>;
  'POST /export-destinations': Endpoint<ExportDestinationCreate, ExportDestination>;
  'PATCH /export-destinations/:id': Endpoint<ExportDestinationUpdate, ExportDestination>;
  'DELETE /export-destinations/:id': Endpoint<Update, Deleted>;
  'POST /exports': Endpoint<AuditExportCreate, ExportRecord>;
  'GET /exports': Endpoint<undefined, Page<ExportRecord>, PageQuery>;
  'GET /exports/:id': Endpoint<undefined, ExportRecord>;
  'POST /channels/setup': Endpoint<ChannelSetup, ChannelSetupFlow>;
  'GET /channels/setup/:id': Endpoint<undefined, ChannelSetupFlow>;
  'GET /channels/oauth/callback': Endpoint<undefined, ChannelSetupFlow, OAuthCallbackQuery>;
  'POST /channels/principal-links': Endpoint<ChannelLinkCreate, ChannelPrincipalLink>;
  'GET /channels/principal-links': Endpoint<undefined, Page<ChannelPrincipalLink>, PageQuery>;
  'DELETE /channels/principal-links/:id': Endpoint<Update, Deleted>;
  'POST /email/address/check': Endpoint<EmailAddressCheck, EmailAddressAvailability>;
  'POST /email/address/claim': Endpoint<EmailAddressClaim, EmailAccount>;
  'GET /email/accounts': Endpoint<undefined, Page<EmailAccount>, PageQuery>;
  'GET /email/accounts/:id/messages': Endpoint<undefined, Page<EmailMessage>, PageQuery & { query?: string; sender?: string }>;
  'GET /email/messages/:id': Endpoint<undefined, EmailMessage>;
  'POST /x/connections': Endpoint<XConnect, XConnectResult>;
  'GET /x/connections': Endpoint<undefined, Page<XConnection>, PageQuery>;
  'PATCH /x/connections/:id': Endpoint<XConnectionUpdate, XConnection>;
  'DELETE /x/connections/:id': Endpoint<Update, Deleted>;
  'GET /x/oauth/callback': Endpoint<undefined, XConnection, OAuthCallbackQuery>;
  'POST /integrations/:providerId/events': Endpoint<IntegrationWebhook, IntegrationIngressReceipt>;
  'POST /integrations/x/mentions': Endpoint<XIngress, IntegrationIngressReceipt>;
  'GET /integration-tokens': Endpoint<undefined, Page<IntegrationToken>, PageQuery>;
  'POST /integration-tokens': Endpoint<IntegrationTokenCreate, IntegrationTokenIssued>;
  'DELETE /integration-tokens/:id': Endpoint<Update, Deleted>;
  'GET /scim/v2/ServiceProviderConfig': Endpoint<undefined, SCIMServiceProviderConfig>;
  'GET /scim/v2/ResourceTypes': Endpoint<undefined, SCIMList<SCIMResourceType>, SCIMQuery>;
  'GET /scim/v2/Schemas': Endpoint<undefined, SCIMList<SCIMSchema>, SCIMQuery>;
  'GET /scim/v2/Users': Endpoint<undefined, SCIMList<SCIMUser>, SCIMQuery>;
  'POST /scim/v2/Users': Endpoint<SCIMUserInput, SCIMUser>;
  'GET /scim/v2/Users/:id': Endpoint<undefined, SCIMUser>;
  'PUT /scim/v2/Users/:id': Endpoint<SCIMUserInput, SCIMUser>;
  'PATCH /scim/v2/Users/:id': Endpoint<SCIMPatch, SCIMUser>;
  'DELETE /scim/v2/Users/:id': Endpoint<undefined, undefined>;
  'GET /scim/v2/Groups': Endpoint<undefined, SCIMList<SCIMGroup>, SCIMQuery>;
  'POST /scim/v2/Groups': Endpoint<SCIMGroupInput, SCIMGroup>;
  'GET /scim/v2/Groups/:id': Endpoint<undefined, SCIMGroup>;
  'PUT /scim/v2/Groups/:id': Endpoint<SCIMGroupInput, SCIMGroup>;
  'PATCH /scim/v2/Groups/:id': Endpoint<SCIMPatch, SCIMGroup>;
  'DELETE /scim/v2/Groups/:id': Endpoint<undefined, undefined>;
  'GET /bots/:id/overview': Endpoint<undefined, BotOverview>;
  'GET /bots/:id/presence': Endpoint<undefined, BotPresence>;
  'GET /machines/:id/capabilities': Endpoint<undefined, MachineCapabilities>;
  'GET /bots/:id/grants': Endpoint<undefined, Page<BotGrant>, PageQuery>;
  'PATCH /bots/:id/grants/:grantId': Endpoint<BotGrantUpdate, BotGrant>;
  'GET /activity': Endpoint<undefined, Page<ActivityItem>, ActivityQuery>;
  'GET /upcoming': Endpoint<undefined, Page<UpcomingItem>, UpcomingQuery>;
  'GET /bots/:id/activity': Endpoint<undefined, Page<ActivityItem>, ActivityQuery>;
  'GET /bots/:id/upcoming': Endpoint<undefined, Page<UpcomingItem>, UpcomingQuery>;
  'GET /reminders': Endpoint<undefined, Page<Reminder>, PageQuery & { botId?: ID }>;
  'POST /reminders': Endpoint<ReminderCreate, Reminder>;
  'DELETE /reminders/:id': Endpoint<Update, Reminder>;
  'GET /bots/:id/preference-changes': Endpoint<undefined, Page<PreferenceChange>, PageQuery>;
  'POST /bots/:id/preference-changes': Endpoint<PreferenceChangeCreate, PreferenceChange>;
  'POST /preference-changes/:id/undo': Endpoint<PreferenceUndo, PreferenceChange>;
  'POST /bots/:id/reset': Endpoint<BotReset, BotResetResult>;
  'POST /bots/:id/memory/import/preview': Endpoint<MemoryImportPreviewRequest, MemoryImportPreview>;
  'GET /bots/:id/ideas': Endpoint<undefined, BotIdea[]>;
  'POST /bots/:id/voice/preview': Endpoint<VoicePreviewRequest, SpeechResult>;
  'GET /bots/:id/milestones': Endpoint<undefined, Page<Milestone>, PageQuery>;
  'POST /milestones/:id/ack': Endpoint<Mutation, Milestone>;
  'POST /bots/:id/connectors/setup': Endpoint<ConnectorSetupRequest, ConnectorSetupResult>;
  'POST /connectors/:id/preview': Endpoint<PreviewRequest, Confirmation>;
  'POST /attachments/:id/preview': Endpoint<PreviewRequest, Confirmation>;
  'POST /memory/:id/preview': Endpoint<PreviewRequest, Confirmation>;
  'GET /downloads/:ticket': Endpoint<undefined, BinaryBody>;
  'GET /connectors/oauth/callback': Endpoint<undefined, ConnectorAuth, OAuthCallbackQuery>;
  'GET /setup': Endpoint<undefined, SetupStatus>;
  'POST /setup': Endpoint<SetupRequest, AuthResult>;
  'POST /auth/login': Endpoint<LoginRequest, AuthResult>;
  'POST /auth/invites/accept': Endpoint<AcceptInviteRequest, AuthResult>;
  'POST /auth/reauth': Endpoint<ReauthRequest, ReauthResult>;
  'GET /auth/sessions': Endpoint<undefined, Page<AuthSession>, PageQuery>;
  'DELETE /auth/sessions/:id': Endpoint<Mutation, Deleted>;
  'POST /auth/logout': Endpoint<Mutation, Empty>;
  'GET /me': Endpoint<undefined, User>;
  'PATCH /me': Endpoint<UserUpdate, User>;
  'PUT /me/password': Endpoint<PasswordUpdate, Empty>;
  'POST /me/preview': Endpoint<PreviewRequest, Confirmation>;
  'DELETE /me': Endpoint<AccountDelete, Deleted>;
  'GET /workspace': Endpoint<undefined, Workspace>;
  'PATCH /workspace': Endpoint<WorkspaceUpdate, Workspace>;
  'GET /members': Endpoint<undefined, Page<Member>, PageQuery>;
  'PATCH /members/:id': Endpoint<MemberUpdate, Member>;
  'POST /members/:id/preview': Endpoint<PreviewRequest, Confirmation>;
  'DELETE /members/:id': Endpoint<Confirm, Deleted>;
  'GET /invites': Endpoint<undefined, Page<MemberInvite>, PageQuery>;
  'POST /invites': Endpoint<InviteCreate, InviteIssued>;
  'DELETE /invites/:id': Endpoint<Mutation, Deleted>;
  'GET /devices': Endpoint<undefined, Page<Device>, PageQuery>;
  'POST /devices': Endpoint<DeviceRegister, Device>;
  'PATCH /devices/:id': Endpoint<DeviceUpdate, Device>;
  'DELETE /devices/:id': Endpoint<Mutation, Deleted>;
  'GET /capabilities': Endpoint<undefined, Capabilities>;
  'GET /sync': Endpoint<undefined, Snapshot>;
  'GET /machines': Endpoint<undefined, Page<Machine>, PageQuery>;
  'POST /machines': Endpoint<MachineAttach, MachineAttachResult>;
  'GET /machines/:id': Endpoint<undefined, Machine>;
  'PATCH /machines/:id': Endpoint<MachineUpdate, Machine>;
  'POST /machines/:id/reconnect': Endpoint<MachineReconnect, MachineInvite>;
  'GET /machines/:id/invites': Endpoint<undefined, Page<MachineInvite>, PageQuery>;
  'DELETE /machines/:id/invites/:inviteId': Endpoint<Mutation, Deleted>;
  'GET /machines/:id/host': Endpoint<undefined, HostInfo>;
  'POST /machines/:id/preview': Endpoint<PreviewRequest, Confirmation>;
  'DELETE /machines/:id': Endpoint<Confirm, Deleted>;
  'GET /machines/:id/files': Endpoint<undefined, Page<FileInfo>, FileListQuery>;
  'GET /machines/:id/files/stat': Endpoint<undefined, FileInfo, FilePathQuery>;
  'GET /machines/:id/files/read': Endpoint<undefined, FileChunk, FileReadQuery>;
  'PUT /machines/:id/files': Endpoint<FileWrite, FileInfo>;
  'POST /machines/:id/files/mkdir': Endpoint<FileMkdir, FileInfo>;
  'POST /machines/:id/files/move': Endpoint<FileMove, FileInfo>;
  'POST /machines/:id/files/preview': Endpoint<FilePreview, Confirmation>;
  'DELETE /machines/:id/files': Endpoint<FileDelete, Deleted>;
  'POST /machines/:id/files/import': Endpoint<FileImport, Attachment>;
  'GET /machines/:id/secrets': Endpoint<undefined, Page<Secret>, PageQuery>;
  'PUT /machines/:id/secrets/:name': Endpoint<SecretSet, Secret>;
  'DELETE /machines/:id/secrets/:name': Endpoint<Mutation, Deleted>;
  'POST /machines/:id/terminals': Endpoint<TerminalOpen, Terminal>;
  'GET /terminals/:id': Endpoint<undefined, Terminal>;
  'POST /terminals/:id/input': Endpoint<TerminalInput, Empty>;
  'POST /terminals/:id/resize': Endpoint<TerminalResize, Terminal>;
  'DELETE /terminals/:id': Endpoint<Mutation, Terminal>;
  'GET /bots': Endpoint<undefined, Page<Bot>, PageQuery & { visibility?: Bot['visibility']; query?: string; machineId?: ID; published?: boolean; hidden?: boolean }>;
  'POST /bots': Endpoint<BotCreate, Bot>;
  'GET /bots/:id': Endpoint<undefined, Bot>;
  'PATCH /bots/:id': Endpoint<BotUpdate, Bot>;
  'POST /bots/:id/duplicate': Endpoint<BotDuplicate, Bot>;
  'POST /bots/:id/team-copy': Endpoint<BotTeamCopy, Bot>;
  'POST /bots/:id/preview': Endpoint<PreviewRequest, Confirmation>;
  'DELETE /bots/:id': Endpoint<Confirm, Deleted>;
  'POST /bots/:id/move': Endpoint<BotMove, Bot>;
  'PATCH /bots/:id/sidebar': Endpoint<SidebarUpdate, Bot>;
  'POST /bots/:id/avatar/generate': Endpoint<AvatarGenerate, Attachment>;
  'GET /sections': Endpoint<undefined, Page<Section>, PageQuery>;
  'POST /sections': Endpoint<SectionCreate, Section>;
  'PATCH /sections/:id': Endpoint<SectionUpdate, Section>;
  'DELETE /sections/:id': Endpoint<Update, Deleted>;
  'GET /templates': Endpoint<undefined, Page<BotTemplate>, PageQuery & { query?: string }>;
  'POST /templates': Endpoint<TemplateCreate, BotTemplate>;
  'GET /templates/:id': Endpoint<undefined, BotTemplate>;
  'PATCH /templates/:id': Endpoint<TemplateUpdate, BotTemplate>;
  'DELETE /templates/:id': Endpoint<Update, Deleted>;
  'POST /templates/:id/import': Endpoint<TemplateImport, Bot>;
  'GET /bots/:id/export': Endpoint<undefined, TemplateContent>;
  'POST /bots/import': Endpoint<BotCreate & { content: TemplateContent; acceptedTerms: boolean }, Bot>;
  'GET /conversations': Endpoint<undefined, Page<Conversation>, PageQuery & { botId?: ID; kind?: ConversationKind }>;
  'POST /conversations': Endpoint<ConversationCreate, Conversation>;
  'GET /conversations/:id': Endpoint<undefined, Conversation>;
  'PATCH /conversations/:id': Endpoint<ConversationUpdate, Conversation>;
  'POST /conversations/:id/preview': Endpoint<PreviewRequest, Confirmation>;
  'DELETE /conversations/:id': Endpoint<Confirm, Deleted>;
  'POST /conversations/:id/read': Endpoint<ReadRequest, Conversation>;
  'GET /conversations/:id/composer': Endpoint<undefined, ComposerDraft>;
  'PUT /conversations/:id/composer': Endpoint<ComposerDraftUpdate, ComposerDraft>;
  'GET /conversations/:id/entries': Endpoint<undefined, Page<TranscriptEntry>, PageQuery & { beforeSeq?: number; afterSeq?: number }>;
  'POST /conversations/:id/messages': Endpoint<MessageSend, MessageReceipt>;
  'GET /entries/:id': Endpoint<undefined, TranscriptEntry>;
  'POST /entries/:id/reactions': Endpoint<ReactionRequest, TranscriptEntry>;
  'DELETE /entries/:id/reactions': Endpoint<ReactionRequest, TranscriptEntry>;
  'POST /entries/:id/feedback': Endpoint<FeedbackCreate, Feedback>;
  'GET /runs': Endpoint<undefined, Page<Run>, PageQuery & { conversationId?: ID; botId?: ID; clientNonce?: string; status?: Run['status'] }>;
  'GET /runs/:id': Endpoint<undefined, Run>;
  'POST /runs/:id/cancel': Endpoint<RunCancel, Run>;
  'POST /attachments': Endpoint<AttachmentUpload, Attachment>;
  'GET /attachments': Endpoint<undefined, Page<Attachment>, PageQuery & { conversationId?: ID; botId?: ID }>;
  'GET /attachments/:id': Endpoint<undefined, Attachment>;
  'GET /attachments/:id/download': Endpoint<undefined, Download>;
  'DELETE /attachments/:id': Endpoint<Confirm, Deleted>;
  'GET /approvals': Endpoint<undefined, Page<Approval>, PageQuery & { state?: ResolutionState; botId?: ID }>;
  'GET /approvals/:id': Endpoint<undefined, Approval>;
  'POST /approvals/:id/resolve': Endpoint<ApprovalResolve, Approval>;
  'GET /questions': Endpoint<undefined, Page<Question>, PageQuery & { state?: ResolutionState }>;
  'GET /questions/:id': Endpoint<undefined, Question>;
  'POST /questions/:id/resolve': Endpoint<QuestionResolve, Question>;
  'GET /human-steps/:id': Endpoint<undefined, HumanStep>;
  'POST /human-steps/:id/resolve': Endpoint<HumanStepResolve, HumanStep>;
  'GET /secret-requests/:id': Endpoint<undefined, SecretRequest>;
  'POST /secret-requests/:id/resolve': Endpoint<SecretRequestResolve, SecretRequest>;
  'GET /drafts': Endpoint<undefined, Page<Draft>, PageQuery & { conversationId?: ID; state?: Draft['state'] }>;
  'GET /drafts/:id': Endpoint<undefined, Draft>;
  'PATCH /drafts/:id': Endpoint<DraftUpdate, Draft>;
  'POST /drafts/:id/send': Endpoint<DraftSend, Draft>;
  'POST /drafts/:id/discard': Endpoint<Update, Draft>;
  'GET /skills': Endpoint<undefined, Page<Skill>, PageQuery & { botId?: ID; query?: string }>;
  'POST /skills': Endpoint<SkillCreate, Skill>;
  'GET /skills/:id': Endpoint<undefined, Skill>;
  'PATCH /skills/:id': Endpoint<SkillUpdate, Skill>;
  'DELETE /skills/:id': Endpoint<Update, Deleted>;
  'GET /routines': Endpoint<undefined, Page<Routine>, PageQuery & { botId?: ID; enabled?: boolean }>;
  'POST /routines': Endpoint<RoutineCreate, Routine>;
  'GET /routines/:id': Endpoint<undefined, Routine>;
  'PATCH /routines/:id': Endpoint<RoutineUpdate, Routine>;
  'POST /routines/:id/preview': Endpoint<PreviewRequest, Confirmation>;
  'DELETE /routines/:id': Endpoint<Confirm, Deleted>;
  'POST /routines/:id/test': Endpoint<Mutation, RoutineRun>;
  'GET /routines/:id/runs': Endpoint<undefined, Page<RoutineRun>, PageQuery>;
  'GET /routine-runs/:id': Endpoint<undefined, RoutineRun>;
  'POST /routine-runs/:id/cancel': Endpoint<Mutation, RoutineRun>;
  'POST /routines/:id/webhook-key': Endpoint<Mutation, WebhookKey>;
  'DELETE /routines/:id/webhook-key': Endpoint<Mutation, Empty>;
  'POST /hooks/:routineId': Endpoint<HookRequest, HookReceipt>;
  'GET /bots/:id/memory': Endpoint<undefined, Page<Memory>, PageQuery & { query?: string; scope?: Memory['scope'] }>;
  'POST /bots/:id/memory': Endpoint<MemoryCreate, Memory>;
  'GET /bots/:id/memory/export': Endpoint<undefined, MemoryExport>;
  'POST /bots/:id/memory/import': Endpoint<MemoryImport, MemoryImportResult>;
  'GET /memory/:id': Endpoint<undefined, Memory>;
  'PATCH /memory/:id': Endpoint<MemoryUpdate, Memory>;
  'DELETE /memory/:id': Endpoint<Confirm, Deleted>;
  'GET /search': Endpoint<undefined, Page<SearchHit>, SearchQuery>;
  'GET /notifications': Endpoint<undefined, Page<Notification>, PageQuery & { unread?: boolean }>;
  'PATCH /notifications/:id': Endpoint<NotificationUpdate, Notification>;
  'POST /notifications/read-all': Endpoint<NotificationReadAll, Empty>;
  'GET /usage': Endpoint<undefined, UsageReport, UsageQuery>;
  'GET /audit': Endpoint<undefined, Page<AuditRecord>, PageQuery & { actorId?: ID; resourceId?: ID; fromAtMs?: TimestampMs; toAtMs?: TimestampMs }>;
  'GET /policies': Endpoint<undefined, Policies>;
  'PATCH /policies': Endpoint<PoliciesUpdate, Policies>;
  'POST /policies/rules': Endpoint<PolicyRuleCreate, PolicyRule>;
  'PATCH /policies/rules/:id': Endpoint<PolicyRuleUpdate, PolicyRule>;
  'DELETE /policies/rules/:id': Endpoint<Update, Deleted>;
  'GET /bots/:id/connectors': Endpoint<undefined, Page<Connector>, PageQuery>;
  'POST /bots/:id/connectors': Endpoint<ConnectorCreate, Connector>;
  'PATCH /connectors/:id': Endpoint<ConnectorUpdate, Connector>;
  'DELETE /connectors/:id': Endpoint<Confirm, Deleted>;
  'POST /connectors/:id/auth': Endpoint<Mutation, ConnectorAuth>;
  'GET /connector-auth/:id': Endpoint<undefined, ConnectorAuth>;
  'GET /consents': Endpoint<undefined, Page<ConnectorConsent>, PageQuery>;
  'POST /consents/:id/resolve': Endpoint<ConsentResolve, ConnectorConsent>;
  'DELETE /consents/:id': Endpoint<Update, Deleted>;
  'GET /channels': Endpoint<undefined, Page<ChannelBinding>, PageQuery & { botId?: ID }>;
  'POST /channels': Endpoint<ChannelCreate, ChannelBinding>;
  'PATCH /channels/:id': Endpoint<ChannelUpdate, ChannelBinding>;
  'DELETE /channels/:id': Endpoint<Update, Deleted>;
  'GET /event-sources': Endpoint<undefined, ExternalSource[]>;
  'POST /voice/sessions': Endpoint<VoiceStart, VoiceSession>;
  'GET /voice/sessions/:id': Endpoint<undefined, VoiceSession>;
  'PATCH /voice/sessions/:id': Endpoint<VoiceUpdate, VoiceSession>;
  'POST /voice/sessions/:id/end': Endpoint<Mutation, VoiceSession>;
  'POST /audio/transcriptions': Endpoint<TranscriptionRequest, Transcription>;
  'POST /audio/speech': Endpoint<SpeechRequest, SpeechResult>;
}
export type RestKey = keyof RestEndpoints;
export type RestRequest<K extends RestKey> = RestEndpoints[K]['request'];
export type RestResponse<K extends RestKey> = RestEndpoints[K]['response'];
export type RestQuery<K extends RestKey> = RestEndpoints[K]['query'];
