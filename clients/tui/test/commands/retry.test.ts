import { afterEach, beforeEach, expect, test } from "bun:test";
import { pickNumber } from "../../src/commands/format.ts";
import { errorResult } from "../../src/dev/fake-server.ts";
import type { SessionTreeEntry } from "../../src/protocol/session-tree.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

let h: Harness;
let resets: string[];
let reloads: string[];
let order: string[];

function entry(id: string, role: string, text: string, extra: Partial<SessionTreeEntry> = {}) {
	return {
		id,
		parentId: null,
		type: "message",
		role,
		text,
		isActive: true,
		isLeaf: false,
		rewindable: role === "user",
		...extra,
	} satisfies SessionTreeEntry;
}

const entries = [
	entry("u1", "user", "first prompt"),
	entry("a1", "assistant", "first answer"),
	entry("old", "user", "abandoned prompt", { isActive: false, rewindable: false }),
	entry("u2", "user", "second prompt"),
	entry("a2", "assistant", "partial answer"),
];

const preview = {
	sessionKey: "s",
	sessionId: "native-s",
	entryId: "u2",
	confirmationToken: "token-u2",
	prompt: "second prompt",
	discardedMessages: 2,
	restorePaths: [],
	unrestorableTools: [],
	restoreFiles: false,
	allowPartialRestore: false,
	unrestorableCommands: [],
	unrestorableCommandCount: 0,
};
const confirmed = {
	...preview,
	leafId: "a1",
	restoredPaths: [],
	partialRestore: false,
};

function serveTree(list: SessionTreeEntry[] = entries, pageSize = 500) {
	h.server.onMethod("sessions.tree", (params: { offset?: number; limit?: number }) => {
		const offset = params.offset ?? 0;
		const page = list.slice(offset, offset + (params.limit ?? pageSize));
		return {
			sessionKey: "s",
			sessionId: "native-s",
			leafId: "a2",
			entries: page,
			branches: [],
			totalEntries: list.length,
			offset,
			hasMore: offset + page.length < list.length,
		};
	});
}

beforeEach(async () => {
	h = await createHarness({
		sessionKey: "s",
		cwd: "/repo",
		methods: ["chat.send", "sessions.tree", "sessions.rewind", "chat.history"],
	});
	resets = [];
	reloads = [];
	order = [];
	Object.assign(h.host, {
		resetSession: (key: string) => {
			resets.push(key);
			order.push("reset");
		},
		reloadSession: async (key: string) => {
			reloads.push(key);
			order.push("reload");
		},
		deliverPrompt: (text: string, mode: string) => {
			h.host.deliveries.push({ text, mode: mode as "queue" });
			order.push(`send:${text}`);
		},
	});
	serveTree();
	h.server.onMethod("sessions.rewind", (params: { dryRun?: boolean }) =>
		params.dryRun ? preview : confirmed,
	);
	h.store.focused.addUser("second prompt");
	h.store.focused.lastRunOutcome = "error";
});
afterEach(() => h.stop());

test("rewinds history only to the last prompt, reloads, then resends it", async () => {
	await h.run("/retry");
	const rewinds = h.server.requestsFor("sessions.rewind");
	expect(rewinds.map((request) => request.params)).toEqual([
		{
			sessionKey: "s",
			cwd: "/repo",
			entryId: "u2",
			restoreFiles: false,
			allowPartialRestore: false,
			dryRun: true,
		},
		{
			sessionKey: "s",
			cwd: "/repo",
			entryId: "u2",
			restoreFiles: false,
			allowPartialRestore: false,
			dryRun: false,
			confirmationToken: "token-u2",
		},
	]);
	expect(order).toEqual(["reset", "reload", "send:second prompt"]);
	expect(h.host.deliveries).toEqual([{ text: "second prompt", mode: "queue" }]);
	expect(h.host.draft).toBe("");
	expect(h.host.text).toContain("stays in /tree");
});

test("an aborted turn is retryable too", async () => {
	h.store.focused.lastRunOutcome = "aborted";
	await h.run("/retry");
	expect(h.host.deliveries).toHaveLength(1);
});

test("a completed turn needs --force", async () => {
	h.store.focused.lastRunOutcome = "done";
	await h.run("/retry");
	expect(h.host.text).toContain("nothing to retry");
	expect(h.server.requestsFor("sessions.tree")).toHaveLength(0);
	expect(h.host.deliveries).toEqual([]);

	await h.run("/retry --force");
	expect(h.host.deliveries).toEqual([{ text: "second prompt", mode: "queue" }]);
	expect(h.host.text).toContain("forced retry");
});

test("a session with no recorded run has nothing to retry", async () => {
	h.store.focused.lastRunOutcome = undefined;
	await h.run("/retry");
	expect(h.host.text).toContain("no failed or aborted turn");
	expect(h.server.requestsFor("sessions.tree")).toHaveLength(0);
});

test("is refused while a run is in flight", async () => {
	h.store.focused.busy = true;
	await h.run("/retry");
	expect(h.server.requestsFor("sessions.tree")).toHaveLength(0);
	expect(h.server.requestsFor("sessions.rewind")).toHaveLength(0);
	expect(h.host.deliveries).toEqual([]);
});

test("rejects unknown arguments", async () => {
	await h.run("/retry --files");
	expect(h.host.last?.level).toBe("error");
	expect(h.server.requestsFor("sessions.tree")).toHaveLength(0);
});

test("finds the last user prompt on an earlier tree page", async () => {
	const filler = Array.from({ length: 600 }, (_, index) =>
		entry(`t${index}`, "assistant", "tool chatter"),
	);
	serveTree([...entries.slice(0, 4), ...filler]);
	h.server.onMethod("sessions.rewind", (params: { dryRun?: boolean }) =>
		params.dryRun ? preview : confirmed,
	);
	await h.run("/retry");
	const offsets = h.server
		.requestsFor("sessions.tree")
		.map((request) => pickNumber(request.params, "offset"));
	expect(offsets).toEqual([0, 500, 0]);
	expect(h.host.deliveries).toEqual([{ text: "second prompt", mode: "queue" }]);
});

test("no stored user prompt leaves everything untouched", async () => {
	serveTree([entry("a1", "assistant", "orphan")]);
	await h.run("/retry");
	expect(h.host.text).toContain("nothing to retry");
	expect(h.server.requestsFor("sessions.rewind")).toHaveLength(0);
});

test("a preview failure changes nothing and resends nothing", async () => {
	h.server.failWith("sessions.rewind", "INTERNAL_ERROR", "boom");
	h.host.draft = "typed";
	await h.run("/retry");
	expect(h.host.last?.level).toBe("error");
	expect(h.host.text).toContain("nothing was resent");
	expect(resets).toEqual([]);
	expect(h.host.draft).toBe("typed");
	expect(h.host.deliveries).toEqual([]);
});

test("a refused confirmation leaves the prompt in the draft and does not resend", async () => {
	h.server.onMethod("sessions.rewind", (params: { dryRun?: boolean }) =>
		params.dryRun ? preview : errorResult("CONFLICT", "stale confirmation"),
	);
	await h.run("/retry");
	expect(h.host.draft).toBe("second prompt");
	expect(h.host.deliveries).toEqual([]);
	expect(resets).toEqual([]);
	expect(h.host.last?.level).toBe("error");
});

test("an unverifiable confirmation is not trusted and nothing is resent", async () => {
	h.server.onMethod("sessions.rewind", (params: { dryRun?: boolean }) =>
		params.dryRun ? preview : { ...confirmed, prompt: "something else" },
	);
	await h.run("/retry");
	expect(h.host.text).toContain("could not be verified");
	expect(h.host.deliveries).toEqual([]);
	expect(resets).toEqual([]);
});

test("a failed reload keeps the prompt in the draft and does not resend", async () => {
	Object.assign(h.host, {
		reloadSession: async () => {
			throw new Error("history down");
		},
	});
	await h.run("/retry");
	expect(h.host.draft).toBe("second prompt");
	expect(h.host.deliveries).toEqual([]);
	expect(h.host.text).toContain("history reload failed");
});

test("when the failed prompt never reached storage, it returns to the draft instead of rewinding", async () => {
	h.store.focused.addUser("the prompt that failed before it was stored");
	await h.run("/retry");
	expect(h.host.draft).toBe("the prompt that failed before it was stored");
	expect(h.host.text).toContain("not stored");
	expect(h.server.requestsFor("sessions.rewind")).toHaveLength(1); // preview only
	expect(h.server.requestsFor("sessions.rewind")[0].params).toMatchObject({ dryRun: true });
	expect(resets).toEqual([]);
	expect(h.host.deliveries).toEqual([]);
});
