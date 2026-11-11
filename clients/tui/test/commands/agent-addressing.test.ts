import { afterEach, beforeEach, expect, test } from "bun:test";
import { errorResult } from "../../src/dev/fake-server.ts";
import type { AgentMessageSend } from "../../src/protocol/agent-addressing.ts";
import { NotConnectedError } from "../../src/protocol/errors.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

const methods = [
	"sessions.create",
	"sessions.metadata.patch",
	"agent.identity.list",
	"agent.identity.rename",
	"agent.message.send",
	"agent.message.get",
];
const fresh = "agent:default:tui:local:dm:fresh";
const target = {
	id: "session://target",
	sessionKey: "target",
	kind: "session",
	name: "bob",
	label: "Review",
	status: "running",
};
let h: Harness;

beforeEach(async () => {
	h = await createHarness({ sessionKey: "source", cwd: "/repo", methods });
	h.host.draft = "keep this draft";
	h.server.respondWith("agent.identity.list", { agents: [target] });
	h.server.onMethod("agent.message.send", (params: AgentMessageSend) => ({
		messageId: params.messageId,
		sourceId: params.sourceId,
		targetId: params.target,
		status: "accepted",
		runId: "run-target",
		response: null,
	}));
});
afterEach(() => h.stop());

function sent() {
	return h.server.requestsFor("agent.message.send") as Array<{ params: AgentMessageSend }>;
}

test("a fresh source is persisted before rename; handle is separate from title and draft", async () => {
	h.store.setFocused(fresh);
	h.store.focused.title = "Human title";
	h.server.respondWith("sessions.create", {
		sessionKey: fresh,
		sessionId: "native",
		created: true,
	});
	h.server.onMethod("agent.identity.rename", (params: { id: string; name: string | null }) => {
		expect(h.server.requestsFor("sessions.create").length).toBeGreaterThan(0);
		return {
			agent: {
				id: params.id,
				sessionKey: fresh,
				kind: "session",
				name: params.name,
				label: "Human title",
			},
		};
	});
	await h.run("/agent-name @ALICE");
	expect(h.server.requestsFor("sessions.create")[0].params).toEqual({
		sessionKey: fresh,
		cwd: "/repo",
	});
	expect(h.server.requestsFor("agent.identity.rename")[0].params).toEqual({
		id: `session://${fresh}`,
		name: "alice",
	});
	expect(h.host.text).toContain(`agent @alice · session://${fresh}`);
	expect(h.store.focused.title).toBe("Human title");
	expect(h.host.draft).toBe("keep this draft");
	expect(h.server.requestsFor("chat.send")).toHaveLength(0);
	await h.run("/agent-name --clear");
	expect(h.server.requestsFor("agent.identity.rename")[1].params).toMatchObject({ name: null });
	expect(h.host.last?.text).toContain("handle cleared");
});

test("collisions are visible and do not overwrite the title or claim success", async () => {
	h.store.focused.title = "Title";
	h.server.failWith("agent.identity.rename", "CONFLICT", "name already taken");
	await h.run("/agent-name bob");
	expect(h.host.last?.level).toBe("error");
	expect(h.host.last?.text).toContain("name already taken");
	expect(h.store.focused.title).toBe("Title");
	expect(h.host.draft).toBe("keep this draft");
});

test.each(["agent.identity.rename", "agent.message.send"])(
	"unverified source creation prevents %s",
	async (method) => {
		h.store.setFocused(fresh);
		h.server.respondWith("sessions.create", {
			sessionKey: "other",
			sessionId: "native",
			created: true,
		});
		await h.run(
			method === "agent.identity.rename" ? "/agent-name alice" : "/tell session://target hello",
		);
		expect(h.server.requestsFor(method)).toHaveLength(0);
		expect(h.host.text).toContain("creation was not verified");
		expect(h.store.focusedKey).toBe(fresh);
		expect(h.host.draft).toBe("keep this draft");
	},
);

test("sending from a fresh source persists it without a prompt or focus change", async () => {
	h.store.setFocused(fresh);
	h.server.respondWith("sessions.create", {
		sessionKey: fresh,
		sessionId: "native",
		created: true,
	});
	await h.run("/tell @BOB line one\n  line two");
	expect(h.server.requestsFor("sessions.create")).toHaveLength(1);
	expect(sent()[0].params).toMatchObject({
		sourceId: `session://${fresh}`,
		target: target.id,
		text: "line one\n  line two",
	});
	expect(h.server.requestsFor("chat.send")).toHaveLength(0);
	expect(h.host.text).toContain("accepted — queued/accepted, not an answer");
	expect(h.host.draft).toBe("keep this draft");
});

test.each(["accepted", "outcome_unknown"])(
	"overlapping identical fresh-source sends share one receipt when the send is %s",
	async (status) => {
		h.store.setFocused(fresh);
		const creating = Promise.withResolvers<void>();
		const persisted = Promise.withResolvers<void>();
		h.server.onMethod("sessions.create", async () => {
			if (h.server.requestsFor("sessions.create").length === 2) creating.resolve();
			await persisted.promise;
			return { sessionKey: fresh, sessionId: "native", created: true };
		});
		if (status === "outcome_unknown") {
			h.server.onMethod("agent.message.send", () =>
				errorResult("UNAVAILABLE", "outcome unknown", { retrySafe: false }),
			);
		}

		const first = h.run("/tell session://target hello");
		const second = h.run("/tell session://target hello");
		await creating.promise;
		expect(sent()).toHaveLength(0);
		h.store.setFocused("elsewhere");
		persisted.resolve();
		await Promise.all([first, second]);

		expect(sent()).toHaveLength(1);
		const { messageId, sourceId } = sent()[0].params;
		expect(sourceId).toBe(`session://${fresh}`);
		const duplicate = h.host.notices.filter((notice) => notice.text.startsWith("not resent:"));
		expect(duplicate).toHaveLength(1);
		expect(duplicate[0].level).toBe("warning");
		expect(duplicate[0].text).toContain(`${messageId}; check /tell --status ${messageId}`);
		expect(h.host.text).toContain(
			status === "accepted"
				? "accepted — queued/accepted, not an answer"
				: "outcome_unknown — do not resend; check status",
		);
		expect(h.store.focusedKey).toBe("elsewhere");
		expect(h.host.draft).toBe("keep this draft");
		expect(h.server.requestsFor("chat.send")).toHaveLength(0);

		h.store.setFocused(fresh);
		await h.run("/tell session://target hello");
		expect(sent()).toHaveLength(1);
		expect(h.host.last?.text).toContain(`not resent: ${status} · ${messageId}`);
		h.server.respondWith("agent.message.get", {
			messageId,
			sourceId,
			targetId: target.id,
			status: "accepted",
			runId: "run-target",
			response: null,
		});
		await h.run(`/tell --status ${messageId}`);
		expect(h.host.last?.text).toContain("accepted — queued/accepted, not an answer");
		expect(sent()).toHaveLength(1);
	},
);

test.each(["source", "target", "text"])(
	"overlapping fresh-source sends with different %s remain independent",
	async (difference) => {
		h.store.setFocused(fresh);
		const creating = Promise.withResolvers<void>();
		const persisted = Promise.withResolvers<void>();
		h.server.onMethod("sessions.create", async ({ sessionKey }: { sessionKey: string }) => {
			if (h.server.requestsFor("sessions.create").length === 2) creating.resolve();
			await persisted.promise;
			return { sessionKey, sessionId: `native-${sessionKey}`, created: true };
		});

		const first = h.run("/tell session://target hello");
		if (difference === "source") h.store.setFocused(`${fresh}-other`);
		const second = h.run(
			difference === "target"
				? "/tell session://other hello"
				: difference === "text"
					? "/tell session://target goodbye"
					: "/tell session://target hello",
		);
		await creating.promise;
		expect(sent()).toHaveLength(0);
		persisted.resolve();
		await Promise.all([first, second]);

		expect(sent()).toHaveLength(2);
		expect(new Set(sent().map((request) => request.params.messageId)).size).toBe(2);
		expect(
			h.host.notices.filter((notice) =>
				notice.text.startsWith("accepted — queued/accepted, not an answer"),
			),
		).toHaveLength(2);
		expect(h.host.text).not.toContain("not resent:");
		expect(h.host.draft).toBe("keep this draft");
	},
);

test("handle resolution uses exact normalized name and pins the stable target", async () => {
	h.server.respondWith("agent.identity.list", {
		agents: [{ ...target, id: "session://wrong", sessionKey: "wrong", name: "bobby" }, target],
	});
	await h.run("/tell @Bob hello");
	expect(sent()[0].params.target).toBe("session://target");
	expect(h.server.requestsFor("agent.identity.list")[0].params).toMatchObject({ query: "bob" });
	expect(h.host.text).toContain("session://source → session://target");
});

test("unknown handle, invalid family target, self send and byte overflow never submit", async () => {
	h.server.respondWith("agent.identity.list", { agents: [{ ...target, name: "bobby" }] });
	await h.run("/tell @bob hello");
	expect(h.host.last?.text).toContain("was not found");
	await h.run("/tell agent://task hello");
	await h.run("/tell researcher hello");
	await h.run("/tell session://source hello");
	await h.run(`/tell session://target ${"é".repeat(16385)}`);
	expect(sent()).toHaveLength(0);
	expect(h.host.draft).toBe("keep this draft");
});

test("unknown stable target refusal is visible without a persona or chat fallback", async () => {
	h.server.failWith("agent.message.send", "NOT_FOUND", "target not found");
	await h.run("/tell session://missing hello");
	expect(h.host.last?.text).toContain("failed");
	expect(h.host.last?.text).toContain("target not found");
	expect(h.server.requestsFor("chat.send")).toHaveLength(0);
	expect(h.host.deliveries).toHaveLength(0);
});

test.each(["accepted", "completed", "failed", "outcome_unknown"])(
	"renders authoritative %s without inventing completion",
	async (status) => {
		h.server.onMethod("agent.message.send", (params: AgentMessageSend) => ({
			messageId: params.messageId,
			sourceId: params.sourceId,
			targetId: params.target,
			status,
			response: status === "completed" ? "Visible answer" : null,
		}));
		await h.run("/tell session://target hello");
		expect(h.host.last?.text).toContain(status);
		expect(h.host.last?.text.includes("Visible answer")).toBe(status === "completed");
		expect(h.host.last?.level).toBe(
			status === "failed" ? "error" : status === "outcome_unknown" ? "warning" : "info",
		);
	},
);

test.each(["messageId", "sourceId", "targetId", "status"])(
	"mismatched %s becomes unknown and identical intent is never resent",
	async (field) => {
		h.server.onMethod("agent.message.send", (params: AgentMessageSend) => ({
			messageId: params.messageId,
			sourceId: params.sourceId,
			targetId: params.target,
			status: "completed",
			[field]: "wrong",
			response: "untrusted answer",
		}));
		await h.run("/tell session://target hello");
		expect(h.host.last?.text).toContain("outcome_unknown");
		expect(h.host.text).not.toContain("untrusted answer");
		await h.run("/tell session://target hello");
		expect(sent()).toHaveLength(1);
		expect(h.host.last?.text).toContain("not resent");
	},
);

test("unknown server mutation reconciles by read, never send, and rejects another target's result", async () => {
	h.server.onMethod("agent.message.send", () =>
		errorResult("UNAVAILABLE", "outcome unknown", { retrySafe: false }),
	);
	await h.run("/tell session://target hello");
	const { messageId, sourceId } = sent()[0].params;
	h.server.respondWith("agent.message.get", {
		messageId,
		sourceId,
		targetId: "session://other",
		status: "completed",
		response: "wrong",
	});
	await h.run(`/tell --status ${messageId}`);
	expect(h.host.last?.text).toContain("does not match");
	h.server.respondWith("agent.message.get", {
		messageId,
		sourceId,
		targetId: target.id,
		status: "completed",
		response: "correct",
	});
	await h.run(`/tell --status ${messageId}`);
	expect(h.host.last?.text).toContain("peer response: correct");
	expect(sent()).toHaveLength(1);
	h.store.setFocused("other-source");
	await h.run(`/tell --status ${messageId}`);
	expect(h.host.last?.text).toContain("different source session");
	expect(h.server.requestsFor("agent.message.get")).toHaveLength(2);
});

test("a focus change during lookup does not borrow the newly focused sender or alter draft", async () => {
	h.server.onMethod("agent.identity.list", () => {
		h.store.setFocused("elsewhere");
		return { agents: [target] };
	});
	await h.run("/tell @bob hello");
	expect(sent()[0].params.sourceId).toBe("session://source");
	expect(h.store.focusedKey).toBe("elsewhere");
	expect(h.host.draft).toBe("keep this draft");
});

test("offline commands and even queue-enabled direct wrappers never queue mutations", async () => {
	h.client.close();
	await h.run("/tell session://target hello");
	await h.run("/agent-name alice");
	await h.run("/agents");
	expect(h.host.text).toContain("not sent or queued");
	await expect(
		h.methods.agentMessageSend(
			{ sourceId: "session://source", target: target.id, text: "hello", messageId: "fixed" },
			{ queueIfOffline: true },
		),
	).rejects.toBeInstanceOf(NotConnectedError);
	await expect(
		h.methods.agentIdentityRename(
			{ id: "session://source", name: "alice" },
			{ queueIfOffline: true },
		),
	).rejects.toBeInstanceOf(NotConnectedError);
	expect(sent()).toHaveLength(0);
	expect(h.server.requestsFor("agent.identity.rename")).toHaveLength(0);
	expect(h.host.draft).toBe("keep this draft");
});

test("unsupported methods refuse without speculative RPCs", async () => {
	h.stop();
	h = await createHarness({ methods: ["agents.list"] });
	await h.run("/agents");
	await h.run("/agent-name alice");
	await h.run("/tell @bob hello");
	expect(h.host.notices.every((notice) => notice.text.includes("unavailable"))).toBe(true);
	expect(sent()).toHaveLength(0);
	expect(h.server.requestsFor("agent.identity.list")).toHaveLength(0);
});

test("failed roster reads are not empty or idle and absent status remains unknown", async () => {
	h.server.failWith("agent.identity.list", "UNAVAILABLE", "owner unreachable");
	await h.run("/agents bob");
	expect(h.host.last?.level).toBe("error");
	expect(h.host.last?.text).not.toContain("agents — 0");
	h.server.respondWith("agent.identity.list", { agents: [{ ...target, status: undefined }] });
	await h.run("/agents bob");
	expect(h.host.last?.text).toContain("unknown");
	expect(h.host.last?.text).toContain("current agent: session://source");
});

test("a rename receipt for another identity never claims the requested name", async () => {
	h.server.respondWith("agent.identity.rename", { agent: { ...target, name: "alice" } });
	await h.run("/agent-name alice");
	expect(h.host.last?.text).toContain("outcome_unknown");
	expect(h.host.last?.text).not.toContain("agent @alice");
});

test("an offline bot target is a visible failure, never a native fallback", async () => {
	h.server.respondWith("agent.identity.list", {
		agents: [
			{
				id: "bot://instance/worker",
				kind: "bot",
				name: "worker",
				label: "Worker",
				status: "offline",
			},
		],
	});
	h.server.failWith("agent.message.send", "UNAVAILABLE", "target offline");
	await h.run("/tell @worker hello");
	expect(sent()[0].params.target).toBe("bot://instance/worker");
	expect(h.host.last?.text).toContain("failed");
	expect(h.host.last?.text).toContain("target offline");
	expect(h.server.requestsFor("chat.send")).toHaveLength(0);
});
