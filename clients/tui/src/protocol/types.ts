/**
 * Payload shapes for control-plane events and methods.
 *
 * Written against the server's own mappers rather than any older client:
 *   - events:  `apps/lemon_control_plane/lib/lemon_control_plane/event_bridge.ex`
 *              (`map_event_type/3` builds every payload below)
 *   - methods: `apps/lemon_control_plane/lib/lemon_control_plane/methods/*.ex`
 *
 * Everything the server can send as `null` is typed optional-or-null: the bridge
 * emits maps with fixed key sets, so absent data arrives as an explicit null.
 */

import type { EventFrame, HelloOkFrame } from "./frames.ts";

export type Nullable<T> = T | null | undefined;

// ---------------------------------------------------------------------------
// chat events
// ---------------------------------------------------------------------------

/** `chat` event, `type: "delta"` — the streaming token channel. */
export interface ChatDeltaEvent {
	type: "delta";
	runId: string;
	sessionKey: Nullable<string>;
	/** Monotonic per run. Drop any delta whose seq is <= the last one seen. */
	seq: number;
	text: string;
}

export type ChatEvent = ChatDeltaEvent;

// ---------------------------------------------------------------------------
// agent events
// ---------------------------------------------------------------------------

export interface AgentStartedEvent {
	type: "started";
	runId: string;
	sessionKey: Nullable<string>;
	engine?: Nullable<string>;
	parentRunId?: Nullable<string>;
	/**
	 * The model the router *resolved* for this run. Nothing on the daemon persists
	 * it, so this event is the only place it is ever observable — which makes it
	 * the authority over anything the client set locally.
	 */
	model?: Nullable<string>;
	provider?: Nullable<string>;
	thinkingLevel?: Nullable<string>;
}

/** `LemonControlPlane.UsageTokens.normalize/1`. Every field may be absent. */
export interface RunUsage {
	inputTokens?: Nullable<number>;
	outputTokens?: Nullable<number>;
	cacheReadTokens?: Nullable<number>;
	cacheWriteTokens?: Nullable<number>;
	totalTokens?: Nullable<number>;
	/**
	 * The input side of the last turn including cached reads — how large the
	 * conversation was going into the model, which is what a context gauge wants.
	 * Excludes output by design.
	 */
	contextTokens?: Nullable<number>;
	costUsd?: Nullable<number>;
}

export interface AgentCompletedEvent {
	type: "completed";
	runId: string;
	sessionKey: Nullable<string>;
	ok: Nullable<boolean>;
	/**
	 * Server-truncated to 500 bytes. The accumulated delta buffer is the source
	 * of truth for final text; this is a fallback for runs with no deltas.
	 */
	answer: Nullable<string>;
	durationMs: Nullable<number>;
	/** Null when the engine reported no token counts at all. */
	usage?: Nullable<RunUsage>;
	model?: Nullable<string>;
}

export type AgentActionKind =
	| "tool"
	| "command"
	| "file_change"
	| "web_search"
	| "subagent"
	| "reasoning"
	| "note";

export interface AgentAction {
	id: Nullable<string>;
	kind: Nullable<AgentActionKind | string>;
	title: Nullable<string>;
	detail: Nullable<Record<string, unknown>>;
}

export type AgentActionPhase = "started" | "updated" | "completed";

export interface AgentToolUseEvent {
	type: "tool_use";
	runId: Nullable<string>;
	sessionKey: Nullable<string>;
	action: AgentAction;
	phase: AgentActionPhase | string;
	ok?: Nullable<boolean>;
	message?: Nullable<string>;
}

export interface AgentCheckpointEvent {
	type: "checkpoint_created" | "checkpoint_restored" | "checkpoint_deleted";
	runId: Nullable<string>;
	sessionKey: Nullable<string>;
	checkpointId: Nullable<string>;
	checkpointKind: Nullable<string>;
	tool: Nullable<string>;
	action: Nullable<string>;
	pathCount: Nullable<number>;
	paths: Nullable<string[]>;
	restoredCount: Nullable<number>;
}

export type AgentEvent =
	| AgentStartedEvent
	| AgentCompletedEvent
	| AgentToolUseEvent
	| AgentCheckpointEvent;

// ---------------------------------------------------------------------------
// approvals
// ---------------------------------------------------------------------------

export interface ApprovalRequestedEvent {
	approvalId: string;
	runId: Nullable<string>;
	sessionKey: Nullable<string>;
	agentId: Nullable<string>;
	tool: Nullable<string>;
	action: Record<string, unknown>;
	rationale: Nullable<string>;
	requestedAtMs: Nullable<number>;
	expiresAtMs: Nullable<number>;
}

export type ApprovalDecision = "once" | "session" | "global" | "deny" | string;

export interface ApprovalResolvedEvent {
	approvalId: string;
	decision: ApprovalDecision;
	runId: Nullable<string>;
	sessionKey: Nullable<string>;
	agentId: Nullable<string>;
	tool: Nullable<string>;
}

// ---------------------------------------------------------------------------
// goal / system events
// ---------------------------------------------------------------------------

export type GoalEventType =
	| "goal_set"
	| "goal_paused"
	| "goal_resumed"
	| "goal_completed"
	| "goal_cleared"
	| "goal_continuation_submitted"
	| "goal_loop_verdict"
	| "goal_loop_status";

export interface GoalEvent {
	type: GoalEventType | string;
	sessionKey: Nullable<string>;
	goalId: Nullable<string>;
	agentId: Nullable<string>;
	status: Nullable<string>;
	objectiveBytes: Nullable<number>;
	continuationCount: Nullable<number>;
	lastRunId: Nullable<string>;
	loopStatus: Nullable<string>;
	loopVerdict: Nullable<string>;
}

export interface TickEvent {
	timestampMs: number;
}

export interface PresenceEvent {
	connections: unknown[];
	count: number;
}

/** `health` and `shutdown` forward their bus payload verbatim. */
export type HealthEvent = Record<string, unknown>;
export type ShutdownEvent = Record<string, unknown>;

export interface LogEvent {
	level: Nullable<string>;
	message: Nullable<string>;
	timestampMs: number;
	runId?: string;
	sessionKey?: string;
}

export interface TaskLifecycleEvent {
	taskId: Nullable<string>;
	parentRunId: Nullable<string>;
	runId: Nullable<string>;
	sessionKey: Nullable<string>;
	agentId: Nullable<string>;
	[key: string]: unknown;
}

export interface ChannelDeliveryEvent {
	intentId: Nullable<string>;
	runId: Nullable<string>;
	sessionKey: Nullable<string>;
	channelId: Nullable<string>;
	accountId: Nullable<string>;
	peerKind: Nullable<string>;
	peerId: Nullable<string>;
	threadId: Nullable<string>;
	kind: Nullable<string>;
	textPreview: Nullable<string>;
	ok: Nullable<boolean>;
	error: Nullable<string>;
	durationMs: Nullable<number>;
	tsMs: Nullable<number>;
}

// ---------------------------------------------------------------------------
// event name -> payload map (drives the client's typed demux)
// ---------------------------------------------------------------------------

export interface ProtocolEventMap {
	chat: ChatEvent;
	agent: AgentEvent;
	goal: GoalEvent;
	tick: TickEvent;
	presence: PresenceEvent;
	health: HealthEvent;
	shutdown: ShutdownEvent;
	heartbeat: Record<string, unknown>;
	metrics: Record<string, unknown>;
	log: LogEvent;
	cron: Record<string, unknown>;
	"cron.job": Record<string, unknown>;
	"cron.audit": Record<string, unknown>;
	"task.started": TaskLifecycleEvent;
	"task.completed": TaskLifecycleEvent;
	"task.error": TaskLifecycleEvent;
	"task.timeout": TaskLifecycleEvent;
	"task.aborted": TaskLifecycleEvent;
	"run.graph.changed": Record<string, unknown>;
	"exec.approval.requested": ApprovalRequestedEvent;
	"exec.approval.resolved": ApprovalResolvedEvent;
	"channel.delivery": ChannelDeliveryEvent;
	"talk.mode": { sessionKey: Nullable<string>; mode: string };
	"voicewake.changed": Record<string, unknown>;
	custom: Record<string, unknown>;
}

export type ProtocolEventName = keyof ProtocolEventMap & string;

/** Client-side lifecycle notifications, emitted on the same bus as events. */
export interface ClientLifecycleMap {
	/** Connection state transitions. */
	state: { state: ConnectionState; previous: ConnectionState };
	/** A completed handshake. `resumed` is true for every hello-ok after the first. */
	"hello-ok": { hello: HelloOkFrame; resumed: boolean };
	/** Emitted after a re-handshake: cached transcript/session state is stale. */
	"resync-needed": { hello: HelloOkFrame };
	/** A request was parked because the client is not online. */
	queued: { id: string; method: string; params: unknown; queueLength: number };
	/** A parked request was sent after reconnecting. */
	"queue-flushed": { id: string; method: string; queueLength: number };
	/** Any server frame that is not a res/hello-ok, before demux. */
	frame: EventFrame;
	/** An event whose name has no entry in {@link ProtocolEventMap}. */
	"unknown-event": EventFrame;
	/** Transport or decode failures worth surfacing but not fatal. */
	"client-error": { error: unknown; context: string };
}

export type ClientEventMap = ProtocolEventMap & ClientLifecycleMap;

export type ConnectionState = "connecting" | "online" | "offline" | "reconnecting";

// ---------------------------------------------------------------------------
// method params / results
// ---------------------------------------------------------------------------

export interface ConnectParams {
	role?: string;
	auth?: { token: string };
	client?: { id: string; [key: string]: unknown };
	[key: string]: unknown;
}

export type QueueMode = "collect" | "followup" | "steer" | "redirect" | "interrupt";

export interface ChatSendParams {
	sessionKey: string;
	prompt: string;
	agentId?: string;
	queueMode?: QueueMode;
}

export interface ChatSendResult {
	runId: string;
	sessionKey: string;
	summary?: Record<string, unknown>;
}

// ---------------------------------------------------------------------------
// profiles
// ---------------------------------------------------------------------------

/** Canonical user-managed profile projection from `LemonCore.ProfileStore`. */
export interface LemonProfile {
	id: string;
	name: string;
	description?: Nullable<string>;
	avatar?: Nullable<string>;
	model?: Nullable<string>;
	node?: Nullable<string>;
	canonicalSessionKey: string;
	/** Present on lifecycle reads; clients must not use it as caller-controlled routing. */
	paths?: Record<string, unknown>;
}

/** Roster adds live named-node availability to the canonical profile record. */
export interface ProfileRosterEntry extends LemonProfile {
	availability: "local" | "online" | "offline" | string;
}

export interface ProfilesListResult {
	profiles: LemonProfile[];
	count: number;
}

export interface ProfilesRosterResult {
	profiles: ProfileRosterEntry[];
	count: number;
	availabilityCounts?: Record<string, number>;
}

export interface ProfileResult {
	profile: LemonProfile;
	summary?: Record<string, unknown>;
}

export interface ProfileCreateParams {
	id: string;
	name?: string;
	description?: string;
	avatar?: string;
	model?: string;
	systemPrompt?: string;
	node?: string;
}

export interface ProfileCloneParams extends Omit<ProfileCreateParams, "id"> {
	sourceId: string;
	id: string;
}

export interface ProfileExportResult {
	export: {
		profileId: string;
		path: string;
		fileCount: number;
		omittedCount: number;
		redactionCount: number;
	};
	summary?: Record<string, unknown>;
}

export interface ProfileDeleteResult {
	deleted: {
		id: string;
		canonicalSessionKey: string;
		homeMoved: boolean;
		trashPath?: Nullable<string>;
	};
	summary?: Record<string, unknown>;
}

export interface ProfileChatParams {
	id: string;
	prompt: string;
	model?: string;
	queueMode?: QueueMode;
}

export interface ProfileChatResult {
	runId: string;
	profileId: string;
	sessionKey: string;
	node?: Nullable<string>;
	summary?: Record<string, unknown>;
}

// ---------------------------------------------------------------------------
// portable automation blueprints
// ---------------------------------------------------------------------------

/**
 * Blueprint replies are intentionally typed only to the content-free fields
 * the terminal client is allowed to retain. The daemon may include additional
 * manifest presentation fields; TUI callers must normalize and discard them.
 */
export interface BlueprintCatalogEntry {
	id: string;
	skills?: Array<{ key?: string; [key: string]: unknown }>;
	automations?: Array<{ id?: string; enabled?: boolean; [key: string]: unknown }>;
	summary?: Record<string, unknown>;
	[key: string]: unknown;
}

export interface BlueprintsListResult {
	bundles?: BlueprintCatalogEntry[];
	summary?: Record<string, unknown>;
	[key: string]: unknown;
}

export interface BlueprintInspectResult extends BlueprintCatalogEntry {
	validation?: Record<string, unknown>;
}

export interface BlueprintPreviewResult {
	bundleId: string;
	profile: { id: string; [key: string]: unknown };
	confirmationDigest: string;
	canActivate?: boolean;
	skills?: Array<{
		key?: string;
		action?: string;
		fileCount?: number;
		bytes?: number;
		[key: string]: unknown;
	}>;
	automation?: {
		id?: string;
		action?: string;
		enabled?: boolean;
		[key: string]: unknown;
	};
	[key: string]: unknown;
}

export interface BlueprintActivationResult {
	activated?: boolean;
	bundleId: string;
	profileId: string;
	confirmationDigest?: string;
	skills?: Array<{ key?: string; status?: string; [key: string]: unknown }>;
	automation?: { id?: string; status?: string; [key: string]: unknown };
	summary?: Record<string, unknown>;
	[key: string]: unknown;
}

export interface ChatAbortParams {
	runId?: string;
	sessionKey?: string;
}

export interface ChatAbortResult {
	aborted: boolean;
	runId?: string;
	sessionKey?: string;
	summary?: Record<string, unknown>;
}

export interface ChatHistoryParams {
	sessionKey: string;
	/** Server clamps to 200. */
	limit?: number;
	beforeId?: string;
	includeFullText?: boolean;
}

export interface ChatHistoryMessage {
	id: string;
	role: "user" | "assistant" | string;
	content: string;
	timestampMs: Nullable<number>;
	truncated?: boolean;
	[key: string]: unknown;
}

export interface ChatHistoryResult {
	sessionKey: string;
	messages: ChatHistoryMessage[];
	summary?: Record<string, unknown>;
}

export interface SessionSummary {
	sessionKey?: string;
	agentId?: string;
	origin?: Nullable<string>;
	createdAtMs?: Nullable<number>;
	updatedAtMs?: Nullable<number>;
	runCount?: Nullable<number>;
	title?: Nullable<string>;
	pinned?: Nullable<boolean>;
	archived?: Nullable<boolean>;
	metadataUpdatedAtMs?: Nullable<number>;
	/**
	 * `sessions.list` only reports the session's *override* here — the model the
	 * user pinned, and null when the session inherits one. Full resolution costs a
	 * profile lookup per row, so it lives in `session.detail`.
	 */
	model?: Nullable<string>;
	[key: string]: unknown;
}

/**
 * The `session` block of a `session.detail` reply.
 *
 * Unlike a listing row, `model` here is what the session's *next run* resolves to,
 * with `modelSource` naming the layer that supplied it and `modelOverride` carrying
 * the session's own pin (null when it inherits).
 */
export interface SessionRouting {
	sessionKey?: string;
	agentId?: Nullable<string>;
	model?: Nullable<string>;
	provider?: Nullable<string>;
	contextWindow?: Nullable<number>;
	maxOutput?: Nullable<number>;
	modelSource?: Nullable<"session" | "profile" | "default">;
	modelOverride?: Nullable<string>;
	thinkingLevel?: Nullable<string>;
	/** Read-only provenance for the runtime that will execute the next run. */
	engine?: Nullable<string>;
	[key: string]: unknown;
}

export interface SessionDetailResult {
	sessionKey?: string;
	session?: SessionRouting;
	[key: string]: unknown;
}

export interface SessionsListResult {
	sessions?: SessionSummary[];
	total?: number;
	filters?: Record<string, unknown>;
	summary?: Record<string, unknown>;
	[key: string]: unknown;
}

export interface SessionsListParams {
	limit?: number;
	offset?: number;
	agentId?: string;
	query?: string;
	pinned?: boolean;
	archived?: boolean;
}

export interface SessionPreviewEntry {
	runId?: string;
	prompt?: Nullable<string>;
	answer?: Nullable<string>;
	ok?: Nullable<boolean>;
	timestampMs?: Nullable<number>;
	truncated?: boolean;
}

export interface SessionsPreviewResult {
	sessionKey: string;
	preview: SessionPreviewEntry[];
	summary?: Record<string, unknown>;
}

export interface SessionsMetadataPatchParams {
	sessionKey: string;
	title?: string | null;
	pinned?: boolean;
	archived?: boolean;
}

export interface SessionsMetadataPatchResult {
	success: boolean;
	sessionKey: string;
	metadata: {
		titlePresent: boolean;
		titleBytes: number;
		pinned: boolean;
		archived: boolean;
		updatedAtMs?: Nullable<number>;
	};
	summary?: Record<string, unknown>;
}

export type SessionExportFormat = "json" | "markdown";

export interface SessionsExportResult {
	sessionKey: string;
	format: SessionExportFormat;
	filename: string;
	content: string;
	sha256: string;
	bytes: number;
	redacted: true;
	summary?: {
		runCount?: number;
		availableRunCount?: number;
		omittedRunCount?: number;
		exportedAtMs?: number;
		cleanup?: Record<string, unknown>;
	};
}

export interface SessionsPruneParams {
	olderThanMs: number;
	archivedOnly?: boolean;
	includePinned?: boolean;
	dryRun?: boolean;
	confirmToken?: string;
}

export interface SessionsPruneResult {
	dryRun: boolean;
	olderThanMs: number;
	archivedOnly: boolean;
	includePinned: boolean;
	confirmToken: string;
	candidateSessionKeys: string[];
	candidateCount: number;
	deletedSessionKeys: string[];
	deletedCount: number;
	verified: boolean;
	summary?: Record<string, unknown>;
}

export interface SessionsDeleteResult {
	deleted: boolean;
	sessionKey: string;
	summary?: {
		sessionKey?: string;
		deleted?: boolean;
		existed?: boolean;
		verified?: boolean;
		cleanup?: Record<string, unknown>;
	};
}

export interface SessionsPatchParams {
	sessionKey: string;
	[key: string]: unknown;
}

export interface ApprovalResolveParams {
	approvalId: string;
	decision: ApprovalDecision;
	[key: string]: unknown;
}

export interface UsageStatusResult {
	[key: string]: unknown;
}

export interface HealthResult {
	[key: string]: unknown;
}

export interface ModelsListResult {
	models?: Array<Record<string, unknown>>;
	[key: string]: unknown;
}

export interface GoalSetParams {
	sessionKey?: string;
	objective?: string;
	[key: string]: unknown;
}

export interface LogsTailParams {
	limit?: number;
	[key: string]: unknown;
}

export interface ConfigGetParams {
	key?: string;
	[key: string]: unknown;
}

export interface ConfigSetParams {
	key: string;
	value: unknown;
	[key: string]: unknown;
}
