/**
 * The control plane's `subagents.*` surface: the Agent Hub's session-scoped
 * roster, transcript, message and cancel operations on native `task` children.
 *
 * Everything is parsed defensively: rows without a task ID or a known status
 * are dropped and mistyped fields degrade to absent. Display text (names,
 * descriptions, activity, transcripts) is child output and therefore untrusted;
 * renderers sanitize it before display.
 */

export type SubagentStatus =
	| "queued"
	| "running"
	| "idle"
	| "parked"
	| "completed"
	| "failed"
	| "cancelled";

const STATUSES: Record<string, true> = {
	queued: true,
	running: true,
	idle: true,
	parked: true,
	completed: true,
	failed: true,
	cancelled: true,
};

export interface SubagentUsage {
	tokens?: number;
	costUsd?: number;
	requests?: number;
	input?: number;
	output?: number;
}

export interface Subagent {
	taskId: string;
	status: SubagentStatus;
	depth: number;
	messaging: boolean;
	cancellable: boolean;
	parentTaskId?: string;
	name?: string;
	agent?: string;
	description?: string;
	model?: string;
	activity?: string;
	createdAtMs?: number;
	startedAtMs?: number;
	completedAtMs?: number;
	updatedAtMs?: number;
	contextPercent?: number;
	usage?: SubagentUsage;
}

export interface SubagentTranscript {
	taskId: string;
	status: SubagentStatus;
	text: string;
	truncated: boolean;
}

export type SubagentDelivery = "injected" | "woken" | "revived" | "failed" | "outcome_unknown";

export interface SubagentSendResult {
	taskId: string;
	accepted: boolean;
	delivery: SubagentDelivery;
	/** False when the message may already have been delivered: never resend automatically. */
	retrySafe: boolean;
}

/** The daemon's message bound (`Control`'s 32 KiB). */
export const SUBAGENT_MESSAGE_MAX_BYTES = 32 * 1024;

export function parseSubagents(value: unknown): Subagent[] {
	const wire = record(value);
	if (!wire || !Array.isArray(wire.agents)) throw new Error("subagents.list returned no roster");
	const agents: Subagent[] = [];
	for (const entry of wire.agents) {
		const agent = parseSubagent(entry);
		if (agent) agents.push(agent);
	}
	return agents;
}

export function parseSubagent(value: unknown): Subagent | undefined {
	const wire = record(value);
	const taskId = str(wire?.taskId);
	const status = str(wire?.status);
	if (!wire || !taskId || !status || !Object.hasOwn(STATUSES, status)) return undefined;
	const agent: Subagent = {
		taskId,
		status: status as SubagentStatus,
		depth: count(wire.depth) ?? 0,
		messaging: wire.messaging === true,
		cancellable: wire.cancellable === true,
	};
	for (const field of [
		"parentTaskId",
		"name",
		"agent",
		"description",
		"model",
		"activity",
	] as const) {
		const text = str(wire[field]);
		if (text) agent[field] = text;
	}
	for (const field of [
		"createdAtMs",
		"startedAtMs",
		"completedAtMs",
		"updatedAtMs",
		"contextPercent",
	] as const) {
		const value = num(wire[field]);
		if (value !== undefined) agent[field] = value;
	}
	const usage = record(wire.usage);
	if (usage) {
		const parsed: SubagentUsage = {};
		for (const field of ["tokens", "costUsd", "requests", "input", "output"] as const) {
			const value = num(usage[field]);
			if (value !== undefined) parsed[field] = value;
		}
		if (Object.keys(parsed).length > 0) agent.usage = parsed;
	}
	return agent;
}

export function parseSubagentTranscript(value: unknown, taskId: string): SubagentTranscript {
	const wire = record(value);
	const status = str(wire?.status);
	if (!wire || wire.taskId !== taskId || typeof wire.text !== "string" || !status) {
		throw new Error("subagents.transcript returned no transcript");
	}
	return {
		taskId,
		status: Object.hasOwn(STATUSES, status) ? (status as SubagentStatus) : "failed",
		text: wire.text,
		truncated: wire.truncated === true,
	};
}

const DELIVERIES: Record<string, true> = {
	injected: true,
	woken: true,
	revived: true,
	failed: true,
	outcome_unknown: true,
};

/** A reply without a recognisable delivery is not a receipt: treat it as unknown, never as sent. */
export function parseSubagentSend(value: unknown, taskId: string): SubagentSendResult {
	const wire = record(value);
	const delivery = str(wire?.delivery);
	if (!wire || !delivery || !Object.hasOwn(DELIVERIES, delivery)) {
		return { taskId, accepted: false, delivery: "outcome_unknown", retrySafe: false };
	}
	return {
		taskId,
		accepted: wire.accepted === true,
		delivery: delivery as SubagentDelivery,
		retrySafe: wire.retrySafe !== false && delivery !== "outcome_unknown",
	};
}

function record(value: unknown): Record<string, unknown> | undefined {
	return value !== null && typeof value === "object" && !Array.isArray(value)
		? (value as Record<string, unknown>)
		: undefined;
}

function str(value: unknown): string | undefined {
	return typeof value === "string" && value.length > 0 ? value : undefined;
}

function num(value: unknown): number | undefined {
	return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;
}

function count(value: unknown): number | undefined {
	const parsed = num(value);
	return parsed !== undefined && Number.isInteger(parsed) ? parsed : undefined;
}
