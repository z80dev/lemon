/**
 * Authenticated real-control-plane proof for the Agent Hub.
 *
 * Drives the production typed client and the hub controller/component (the
 * same objects Alt+A mounts) against an isolated Bandit listener whose runtime
 * is the real coding-agent provider. The matching ExUnit test plants the task
 * records: a direct and a nested child of the session, and a foreign child
 * of another session.
 */

import { ControlPlaneClient } from "../src/protocol/client.ts";
import { ControlPlaneError } from "../src/protocol/errors.ts";
import { ControlPlaneMethods } from "../src/protocol/methods.ts";
import { TaskTreeController } from "../src/ui/controllers/task-tree-controller.ts";
import { initTheme } from "../src/ui/theme/theme.ts";

const [url, token, sessionKey, directId, nestedId, foreignId] = process.argv.slice(2);
if (!url || !token || !sessionKey || !directId || !nestedId || !foreignId) {
	throw new Error(
		"usage: bun subagents-wire-proof.ts <ws-url> <operator-token> <session-key> <direct> <nested> <foreign>",
	);
}

function assert(condition: unknown, check: string): asserts condition {
	if (!condition) throw new Error(`check failed: ${check}`);
}

async function rejection(promise: Promise<unknown>): Promise<ControlPlaneError> {
	try {
		await promise;
	} catch (error) {
		if (error instanceof ControlPlaneError) return error;
		throw error;
	}
	throw new Error("expected a control-plane refusal");
}

initTheme({ colorLevel: 0 });
const client = new ControlPlaneClient({
	url,
	token,
	clientId: "lemon-tui-subagents-wire-proof",
	requestTimeoutMs: 5_000,
	socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
});
const methods = new ControlPlaneMethods(client);
const notices: string[] = [];
const hub = new TaskTreeController({
	methods,
	online: () => client.online,
	notice: (text) => notices.push(text),
	pollMs: 60_000,
	requestRender() {},
});

try {
	const hello = await client.connect();
	assert(hello.auth?.role === "operator", "operator authentication");

	const agents = await methods.subagentsList({ sessionKey });
	const ids = agents.map((agent) => agent.taskId).sort();
	assert(JSON.stringify(ids) === JSON.stringify([directId, nestedId].sort()), "session lineage");
	const nested = agents.find((agent) => agent.taskId === nestedId);
	assert(nested?.parentTaskId === directId && nested.depth === 1, "nested parent");
	const wire = JSON.stringify(agents);
	assert(!wire.includes("PRIVATE_PROMPT"), "prompt absent from roster");
	assert(!wire.includes("/private/"), "paths absent from roster");

	const foreign = await rejection(methods.subagentsTranscript({ sessionKey, taskId: foreignId }));
	assert(foreign.code === "NOT_FOUND", "foreign transcript not found");
	const foreignCancel = await rejection(methods.subagentsCancel({ sessionKey, taskId: foreignId }));
	assert(foreignCancel.code === "NOT_FOUND", "foreign cancel not found");

	hub.setSession(sessionKey);
	hub.panel.focused = true;
	hub.toggle();
	await hub.refresh(false);
	const roster = hub.panel.render(200).join("\n");
	assert(roster.includes("Researcher @scout"), "hub roster row");
	assert(roster.includes("└─ running"), "hub tree row");

	hub.panel.handleInput("\r");
	await hub.loadTranscript(directId);
	const transcript = hub.panel.render(200).join("\n");
	assert(transcript.includes("Parser mapped"), "hub transcript");
	assert(transcript.includes("this agent can no longer be messaged"), "finished agent input");

	// The nested child is running in the store, but no live control entry owns it.
	const refused = await rejection(
		methods.subagentsSend({ sessionKey, taskId: nestedId, message: "status?" }),
	);
	assert(refused.code === "CONFLICT", "untracked child refuses messages");
	const details = refused.details;
	assert(
		details !== null &&
			typeof details === "object" &&
			"code" in details &&
			details.code === "SUBAGENT_NOT_RESUMABLE",
		"not resumable code",
	);
	const finished = await rejection(methods.subagentsCancel({ sessionKey, taskId: directId }));
	assert(finished.code === "CONFLICT", "finished child refuses cancel");
	assert(!notices.join("\n").includes(token), "operator token absent");

	console.log(
		JSON.stringify({
			ok: true,
			checks: [
				"authenticated_handshake",
				"session_lineage_roster",
				"foreign_ids_not_found",
				"hub_roster_and_transcript",
				"untracked_send_refused",
				"finished_cancel_refused",
			],
		}),
	);
} finally {
	hub.dispose();
	client.close();
}
