/**
 * The control plane's `omp.*` surface: external omp (oh-my-pi) delegate
 * processes the daemon spawns, drives and observes.
 *
 * Shapes follow the `session_wire` / `discovered_wire` projections of
 * `LemonOmp` (camelCase string keys). Everything here is parsed defensively:
 * a field the daemon omits or sends with the wrong type degrades to its empty
 * value instead of throwing, and a row without an identity is dropped. Text
 * fields (titles, activity, todo text, assistant text, errors) are omp output
 * and therefore untrusted — the parser keeps them verbatim; every renderer
 * sanitizes before display.
 */

export type OmpSessionStatus = "starting" | "running" | "idle" | "closed" | "failed" | "unknown";

/** `omp.status`. */
export interface OmpStatus {
	available: boolean;
	version: string | null;
	/** `not_installed` when the daemon could not find an omp binary. */
	reason: string | null;
	live: number;
	maxSessions: number | null;
}

export type OmpOwner = { kind: "agent"; sessionKey: string | null } | { kind: "operator" };

export interface OmpActiveTool {
	id: string | null;
	name: string;
	intent: string | null;
	startedAt: number | null;
}

export interface OmpRecentTool {
	name: string;
	intent: string | null;
	isError: boolean;
	durationMs: number | null;
}

export interface OmpTodo {
	phase: string | null;
	content: string;
	/** `pending | in_progress | completed | abandoned | …` as omp reported it. */
	status: string;
}

export interface OmpSubagent {
	id: string | null;
	agent: string | null;
	status: string | null;
	description: string | null;
	activity: string | null;
	toolCalls: number;
	recentTools: OmpRecentTool[];
	usage: OmpUsage | null;
	model: string | null;
	startedAt: number | null;
	endedAt: number | null;
	durationMs: number | null;
	output: string | null;
	error: string | null;
}

export interface OmpUsage {
	input: number | null;
	output: number | null;
	cacheRead: number | null;
	cacheWrite: number | null;
	totalTokens: number | null;
	cost: number | null;
}

export type OmpApprovalMode = "always-ask" | "write" | "yolo";
export interface OmpPendingApproval {
	id: string;
	tool: string | null;
	details: unknown;
	requestedAt: number | null;
}
export interface OmpWorktree {
	path: string | null;
	branch: string | null;
	base: string | null;
	repo: string | null;
	kept: boolean | null;
	dirty: boolean | null;
	commits: number | null;
}
/** One `session_wire`: a Lemon-side omp invocation and its projected state. */
export interface OmpSession {
	/** Lemon invocation id (`omp_…`); a new one per start/resume. */
	id: string;
	ompSessionId: string | null;
	title: string;
	cwd: string | null;
	model: string | null;
	thinking: string | null;
	approvalMode: OmpApprovalMode | null;
	pendingApprovals: OmpPendingApproval[];
	approvals: { approved: number; denied: number; expired: number };
	worktree: OmpWorktree | null;
	owner: OmpOwner | null;
	status: OmpSessionStatus;
	lastTurn: string | null;
	activity: string | null;
	startedAt: number | null;
	updatedAt: number | null;
	endedAt: number | null;
	turns: number;
	toolCalls: number;
	activeTools: OmpActiveTool[];
	recentTools: OmpRecentTool[];
	todos: OmpTodo[];
	subagents: OmpSubagent[];
	usage: OmpUsage | null;
	/** Percent of the context window in use, 0–100 (omp's `contextUsage.percent`). */
	contextPercent: number | null;
	lastText: string | null;
	result: string | null;
	error: string | null;
	declinedPrompts: number;
	exit: { code: number | null; reason: string | null } | null;
}

/** One `discovered_wire`: an omp session file found on disk for a workspace. */
export interface OmpDiscoveredSession {
	ompSessionId: string;
	title: string;
	cwd: string | null;
	createdAt: number | null;
	updatedAt: number | null;
	model: string | null;
	lastStatus: string;
	/** Another omp process (outside Lemon) appears to hold the session. */
	activeElsewhere: boolean;
	/** The live Lemon invocation already driving it, when there is one. */
	liveId: string | null;
	source: "lemon" | "omp" | null;
	interrupted: boolean;
	worktree: OmpWorktree | null;
}

export type OmpSessionEventReason = "started" | "updated" | "settled" | "exited";

/** The `omp.session` WebSocket event, after parsing. */
export interface OmpSessionEvent {
	reason: OmpSessionEventReason | string;
	session: OmpSession;
}

export type OmpSendMode = "steer" | "followUp" | "redirect";

export interface OmpSessionsListParams {
	includeEnded?: boolean;
	/** Server clamps to 100. */
	limit?: number;
}

export interface OmpSessionsStartParams {
	prompt: string;
	cwd: string;
	model?: string;
	thinking?: string;
	approvalMode?: OmpApprovalMode;
	isolate?: boolean;
}

export interface OmpSessionsResumeParams {
	ompSessionId: string;
	cwd: string;
	prompt?: string;
	model?: string;
	thinking?: string;
	approvalMode?: OmpApprovalMode;
	continue?: boolean;
}

export interface OmpSessionsSendParams {
	id: string;
	/** At most 16 KiB. */
	message: string;
	mode?: OmpSendMode;
}

export interface OmpSessionsListResult {
	sessions: OmpSession[];
}

export interface OmpSessionsGetResult {
	session: OmpSession;
	summary: string | null;
}

export interface OmpSessionsDiscoverResult {
	sessions: OmpDiscoveredSession[];
}

export interface OmpSessionResult {
	session: OmpSession;
}

export interface OmpSendResult {
	accepted: boolean;
	/** `steer`, `followUp`, or `prompt` when an idle session took it as a new turn. */
	delivery: string | null;
}

export interface OmpCancelResult {
	cancelled: boolean;
}

/** Hard limit on `omp.sessions.send` messages (bytes of UTF-8). */
export const OMP_MESSAGE_MAX_BYTES = 16 * 1024;

const STATUSES: Record<string, OmpSessionStatus> = {
	starting: "starting",
	running: "running",
	idle: "idle",
	closed: "closed",
	failed: "failed",
};

/** Ended sessions keep their snapshot but no longer have a process. */
export function isOmpSessionEnded(session: Pick<OmpSession, "status">): boolean {
	return session.status === "closed" || session.status === "failed";
}

/** A process is doing work right now (the status badge counts these). */
export function isOmpSessionBusy(session: Pick<OmpSession, "status">): boolean {
	return session.status === "starting" || session.status === "running";
}

// -- parsing -------------------------------------------------------------------

function record(value: unknown): Record<string, unknown> | undefined {
	return value !== null && typeof value === "object" && !Array.isArray(value)
		? (value as Record<string, unknown>)
		: undefined;
}

function str(value: unknown): string | null {
	return typeof value === "string" && value.length > 0 ? value : null;
}

function num(value: unknown): number | null {
	return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function count(value: unknown): number {
	const n = num(value);
	return n !== null && n > 0 ? Math.floor(n) : 0;
}

function list<T>(value: unknown, parse: (entry: Record<string, unknown>) => T | undefined): T[] {
	if (!Array.isArray(value)) return [];
	const out: T[] = [];
	for (const entry of value) {
		const item = record(entry);
		const parsed = item ? parse(item) : undefined;
		if (parsed !== undefined) out.push(parsed);
	}
	return out;
}

function parseOwner(value: unknown): OmpOwner | null {
	const owner = record(value);
	if (owner?.kind === "operator") return { kind: "operator" };
	if (owner?.kind === "agent") return { kind: "agent", sessionKey: str(owner.sessionKey) };
	return null;
}

function parseUsage(value: unknown): OmpUsage | null {
	const usage = record(value);
	if (!usage) return null;
	return {
		input: num(usage.input),
		output: num(usage.output),
		cacheRead: num(usage.cacheRead),
		cacheWrite: num(usage.cacheWrite),
		totalTokens: num(usage.totalTokens),
		cost: num(usage.cost),
	};
}

function parseWorktree(value: unknown): OmpWorktree | null {
	const tree = record(value);
	return tree
		? {
				path: str(tree.path),
				branch: str(tree.branch),
				base: str(tree.base),
				repo: str(tree.repo),
				kept: typeof tree.kept === "boolean" ? tree.kept : null,
				dirty: typeof tree.dirty === "boolean" ? tree.dirty : null,
				commits: num(tree.commits),
			}
		: null;
}

/** One `session_wire`, or undefined when it carries no Lemon invocation id. */
export function parseOmpSession(value: unknown): OmpSession | undefined {
	const wire = record(value);
	const id = str(wire?.id);
	if (!wire || !id) return undefined;
	const status = str(wire.status);
	const exit = record(wire.exit);
	return {
		id,
		ompSessionId: str(wire.ompSessionId),
		title: str(wire.title) ?? "",
		cwd: str(wire.cwd),
		model: str(wire.model),
		thinking: str(wire.thinking),
		approvalMode:
			wire.approvalMode === "always-ask" ||
			wire.approvalMode === "write" ||
			wire.approvalMode === "yolo"
				? wire.approvalMode
				: null,
		pendingApprovals: list(wire.pendingApprovals, (approval) => {
			const id = str(approval.id);
			return id
				? {
						id,
						tool: str(approval.tool),
						details: approval.details ?? null,
						requestedAt: num(approval.requestedAt),
					}
				: undefined;
		}),
		approvals: {
			approved: count(record(wire.approvals)?.approved),
			denied: count(record(wire.approvals)?.denied),
			expired: count(record(wire.approvals)?.expired),
		},
		worktree: parseWorktree(wire.worktree),
		owner: parseOwner(wire.owner),
		status: (status && Object.hasOwn(STATUSES, status) && STATUSES[status]) || "unknown",
		lastTurn: str(wire.lastTurn),
		activity: str(wire.activity),
		startedAt: num(wire.startedAt),
		updatedAt: num(wire.updatedAt),
		endedAt: num(wire.endedAt),
		turns: count(wire.turns),
		toolCalls: count(wire.toolCalls),
		activeTools: list(wire.activeTools, (tool) => {
			const name = str(tool.name);
			return name
				? { id: str(tool.id), name, intent: str(tool.intent), startedAt: num(tool.startedAt) }
				: undefined;
		}),
		recentTools: list(wire.recentTools, (tool) => {
			const name = str(tool.name);
			return name
				? {
						name,
						intent: str(tool.intent),
						isError: tool.isError === true,
						durationMs: num(tool.durationMs),
					}
				: undefined;
		}),
		todos: list(wire.todos, (todo) => {
			const content = str(todo.content);
			return content
				? { phase: str(todo.phase), content, status: str(todo.status) ?? "pending" }
				: undefined;
		}),
		subagents: list(wire.subagents, (agent) => ({
			id: str(agent.id),
			agent: str(agent.agent),
			status: str(agent.status),
			description: str(agent.description),
			activity: str(agent.activity),
			toolCalls: count(agent.toolCalls),
			recentTools: list(agent.recentTools, (tool) => {
				const name = str(tool.name);
				return name
					? {
							name,
							intent: str(tool.intent),
							isError: tool.isError === true,
							durationMs: num(tool.durationMs),
						}
					: undefined;
			}),
			usage: parseUsage(agent.usage),
			model: str(agent.model),
			startedAt: num(agent.startedAt),
			endedAt: num(agent.endedAt),
			durationMs: num(agent.durationMs),
			output: str(agent.output),
			error: str(agent.error),
		})),
		usage: parseUsage(wire.usage),
		contextPercent: num(wire.contextPercent),
		lastText: str(wire.lastText),
		result: str(wire.result),
		error: str(wire.error),
		declinedPrompts: count(wire.declinedPrompts),
		exit: exit ? { code: num(exit.code), reason: str(exit.reason) } : null,
	};
}

/** Every parseable `session_wire` in an array; anything else yields []. */
export function parseOmpSessions(value: unknown): OmpSession[] {
	if (!Array.isArray(value)) return [];
	const out: OmpSession[] = [];
	for (const entry of value) {
		const session = parseOmpSession(entry);
		if (session) out.push(session);
	}
	return out;
}

/** One `discovered_wire`, or undefined without an omp session id. */
export function parseOmpDiscovered(value: unknown): OmpDiscoveredSession | undefined {
	const wire = record(value);
	const ompSessionId = str(wire?.ompSessionId);
	if (!wire || !ompSessionId) return undefined;
	return {
		ompSessionId,
		title: str(wire.title) ?? "",
		cwd: str(wire.cwd),
		createdAt: num(wire.createdAt),
		updatedAt: num(wire.updatedAt),
		model: str(wire.model),
		lastStatus: str(wire.lastStatus) ?? "unknown",
		activeElsewhere: wire.activeElsewhere === true,
		liveId: str(wire.liveId),
		source: wire.source === "lemon" || wire.source === "omp" ? wire.source : null,
		interrupted: wire.interrupted === true,
		worktree: parseWorktree(wire.worktree),
	};
}

export function parseOmpDiscoveredList(value: unknown): OmpDiscoveredSession[] {
	if (!Array.isArray(value)) return [];
	const out: OmpDiscoveredSession[] = [];
	for (const entry of value) {
		const session = parseOmpDiscovered(entry);
		if (session) out.push(session);
	}
	return out;
}

/** The `omp.session` event payload; undefined when it carries no usable session. */
export function parseOmpSessionEvent(value: unknown): OmpSessionEvent | undefined {
	const payload = record(value);
	const session = parseOmpSession(payload?.session);
	if (!payload || !session) return undefined;
	return { reason: str(payload.reason) ?? "updated", session };
}

export function parseOmpStatus(value: unknown): OmpStatus {
	const status = record(value) ?? {};
	return {
		available: status.available === true,
		version: str(status.version),
		reason: str(status.reason),
		live: count(status.live),
		maxSessions: num(status.maxSessions),
	};
}

export interface OmpModel {
	selector: string;
	provider: string | null;
	id: string | null;
	name: string | null;
	contextWindow: number | null;
	reasoning: boolean;
	costInput: number | null;
	costOutput: number | null;
	free: boolean;
}
export interface OmpModelsParams {
	query?: string;
	provider?: string;
	freeOnly?: boolean;
	limit?: number;
}
export interface OmpConfigureParams {
	id: string;
	model?: string;
	thinking?: string;
}
export interface OmpStartManyParams {
	tasks: OmpSessionsStartParams[];
	isolate?: boolean;
}
export interface OmpStartManyResult {
	results: Array<
		| { index: number; session: OmpSession }
		| { index: number; error: { code: string; message: string; id?: string } }
	>;
}
export interface OmpSubagentResult {
	id: string;
	subagentId: string;
	transcript: {
		messages: Array<{ role: string; text: string; toolName?: string }>;
		fromByte: number;
		nextByte: number;
		reset: boolean;
	};
}
export function parseOmpModels(value: unknown): OmpModel[] {
	return list(value, (model) => {
		const selector = str(model.selector);
		return selector
			? {
					selector,
					provider: str(model.provider),
					id: str(model.id),
					name: str(model.name),
					contextWindow: num(model.contextWindow),
					reasoning: model.reasoning === true,
					costInput: num(model.costInput),
					costOutput: num(model.costOutput),
					free: model.free === true,
				}
			: undefined;
	});
}
export function parseOmpSubagent(value: unknown): OmpSubagentResult {
	const wire = record(value) ?? {};
	const transcript = record(wire.transcript) ?? {};
	return {
		id: str(wire.id) ?? "",
		subagentId: str(wire.subagentId) ?? "",
		transcript: {
			messages: list(transcript.messages, (message) =>
				typeof message.text === "string"
					? {
							role: str(message.role) ?? "unknown",
							text: message.text,
							...(str(message.toolName) ? { toolName: str(message.toolName)! } : {}),
						}
					: undefined,
			),
			fromByte: count(transcript.fromByte),
			nextByte: count(transcript.nextByte),
			reset: transcript.reset === true,
		},
	};
}
