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
	token?: string;
	client?: { id: string; [key: string]: unknown };
	[key: string]: unknown;
}

export type QueueMode = "collect" | "followup" | "steer" | "interrupt";

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
	[key: string]: unknown;
}

export interface SessionsListResult {
	sessions?: SessionSummary[];
	[key: string]: unknown;
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
