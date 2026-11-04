export interface AgentIdentity {
	id: string;
	name: string | null;
	kind: "session" | "bot";
	sessionKey?: string;
	label: string;
	status?: "running" | "idle" | "offline" | "unknown";
}

export interface AgentMessageReceipt {
	messageId: string;
	sourceId: string;
	targetId: string;
	status: "accepted" | "completed" | "failed" | "outcome_unknown";
	runId?: string | null;
	response?: string | null;
	error?: string | null;
}

export interface AgentMessageSend {
	sourceId: string;
	target: string;
	text: string;
	messageId: string;
}

export function isAgentAddress(value: unknown): value is string {
	return typeof value === "string" && /^(session|bot):\/\/[^\s\p{Cc}]+$/u.test(value);
}

function record(value: unknown): Record<string, unknown> {
	if (!value || typeof value !== "object" || Array.isArray(value)) {
		throw new Error("invalid agent response");
	}
	return value as Record<string, unknown>;
}

export function parseAgentIdentity(value: unknown): AgentIdentity {
	const row = record(value);
	if (
		!isAgentAddress(row.id) ||
		(row.kind !== "session" && row.kind !== "bot") ||
		!row.id.startsWith(`${row.kind}://`) ||
		(row.name !== null &&
			(typeof row.name !== "string" || !/^[a-z][a-z0-9_-]{0,63}$/.test(row.name))) ||
		typeof row.label !== "string" ||
		(row.sessionKey !== undefined &&
			(row.kind !== "session" || row.sessionKey !== row.id.slice("session://".length))) ||
		(row.status !== undefined &&
			(typeof row.status !== "string" ||
				!["running", "idle", "offline", "unknown"].includes(row.status)))
	)
		throw new Error("invalid agent identity response");
	return row as unknown as AgentIdentity;
}

export function parseAgentList(value: unknown): { agents: AgentIdentity[] } {
	const row = record(value);
	if (!Array.isArray(row.agents)) throw new Error("invalid agent roster response");
	const agents = row.agents.map(parseAgentIdentity);
	if (new Set(agents.map((agent) => agent.id)).size !== agents.length) {
		throw new Error("duplicate identities in agent roster");
	}
	return { agents };
}

export function parseAgentRename(
	value: unknown,
	id: string,
	name: string | null,
): { agent: AgentIdentity } {
	const agent = parseAgentIdentity(record(value).agent);
	if (agent.id !== id || agent.name !== name)
		throw new Error("agent rename receipt does not match the request");
	return { agent };
}

export function parseAgentReceipt(
	value: unknown,
	expected: { messageId: string; sourceId: string; targetId?: string },
): AgentMessageReceipt {
	const row = record(value);
	if (
		row.messageId !== expected.messageId ||
		row.sourceId !== expected.sourceId ||
		!isAgentAddress(row.targetId) ||
		(expected.targetId !== undefined && row.targetId !== expected.targetId) ||
		typeof row.status !== "string" ||
		!["accepted", "completed", "failed", "outcome_unknown"].includes(row.status) ||
		![row.runId, row.response, row.error].every(
			(value) => value == null || typeof value === "string",
		)
	)
		throw new Error("agent message receipt does not match the request");
	return row as unknown as AgentMessageReceipt;
}
