import { afterEach, beforeEach, expect, test } from "bun:test";
import type { PickerSpec } from "../../src/commands/registry.ts";
import type { SessionTreeResult } from "../../src/protocol/session-tree.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

let h: Harness;
let resets: string[];
let reloads: string[];
const tree: SessionTreeResult = {
	sessionKey: "s",
	sessionId: "native-s",
	leafId: "a2",
	offset: 0,
	totalEntries: 4,
	hasMore: false,
	branches: [
		{ leafId: "a2", active: true },
		{ leafId: "old", active: false },
	],
	entries: [
		{
			id: "u1",
			parentId: null,
			type: "message",
			role: "user",
			text: "first prompt",
			isActive: true,
			isLeaf: false,
			rewindable: true,
		},
		{
			id: "a1",
			parentId: "u1",
			type: "message",
			role: "assistant",
			text: "first answer",
			isActive: true,
			isLeaf: false,
			rewindable: false,
		},
		{
			id: "u2",
			parentId: "a1",
			type: "message",
			role: "user",
			text: "second prompt",
			isActive: true,
			isLeaf: false,
			rewindable: true,
		},
		{
			id: "old",
			parentId: "a1",
			type: "message",
			role: "user",
			text: "abandoned prompt",
			isActive: false,
			isLeaf: true,
			rewindable: false,
		},
	],
};
const preview = {
	sessionKey: "s",
	sessionId: "native-s",
	entryId: "u2",
	confirmationToken: "snapshot-bound-token",
	prompt: "second prompt",
	promptContainsNonText: false,
	discardedMessages: 2,
	restorePaths: ["/repo/file.ts"],
	unrestorableTools: [],
	restoreFiles: false,
	allowPartialRestore: false,
	canAllowPartialRestore: false,
	unrestorableCommands: [],
	unrestorableCommandCount: 0,
};
const filesPreview = { ...preview, restoreFiles: true };
const blockedPreview = {
	...filesPreview,
	canAllowPartialRestore: true,
	unrestorableTools: ["bash"],
	unrestorableCommands: ["printf first", "printf second"],
	unrestorableCommandCount: 2,
};
const partialPreview = {
	...blockedPreview,
	allowPartialRestore: true,
	confirmationToken: "partial-snapshot-bound-token",
};
const partialResult = {
	...partialPreview,
	leafId: "a1",
	restoredPaths: partialPreview.restorePaths,
	partialRestore: true,
};

beforeEach(async () => {
	h = await createHarness({
		sessionKey: "s",
		cwd: "/repo",
		methods: [
			"chat.history",
			"sessions.create",
			"sessions.tree",
			"sessions.rewind",
			"sessions.metadata.patch",
		],
	});
	resets = [];
	reloads = [];
	Object.assign(h.host, {
		resetSession: (key: string) => {
			resets.push(key);
		},
		reloadSession: async (key: string) => {
			reloads.push(key);
		},
	});
	h.host.draft = "keep my draft";
	h.server.respondWith("sessions.tree", tree);
	h.server.respondWith("sessions.rewind", preview);
});
afterEach(() => h.stop());

function picker(): PickerSpec {
	return h.host.pickers.at(-1)!;
}
async function chooseUser(): Promise<void> {
	await picker().onSelect(picker().items.find((item) => item.value === "u2")!);
}

test("tree includes preserved branches, but rewind only offers active user entries", async () => {
	await h.run("/tree");
	expect(picker().items.map((item) => item.value)).toContain("old");
	await h.run("/rewind");
	expect(picker().items.map((item) => item.value)).toEqual(["u1", "u2"]);
	expect(h.server.requestsFor("sessions.tree")[0].params).toMatchObject({
		sessionKey: "s",
		cwd: "/repo",
	});
});

test.each(["cancel", "inspect"])(
	"%s preserves the draft and sends no mutating request",
	async (choice) => {
		await h.run("/rewind");
		await chooseUser();
		expect(picker().items[0].value).toBe("cancel");
		await picker().onSelect(picker().items.find((item) => item.value === choice)!);
		expect(h.server.requestsFor("sessions.rewind").map((request) => request.params)).toEqual([
			{
				sessionKey: "s",
				cwd: "/repo",
				entryId: "u2",
				restoreFiles: false,
				allowPartialRestore: false,
				dryRun: true,
			},
		]);
		expect(h.host.draft).toBe("keep my draft");
		expect(resets).toEqual([]);
	},
);

test("history-only preview never claims checkpointed paths will be restored", async () => {
	await h.run("/rewind");
	await chooseUser();
	expect(h.host.text).toContain("history only · files stay unchanged");
	expect(h.host.text).not.toContain("restore:");
	expect(h.host.text).not.toContain("/repo/file.ts");
	expect(picker().detail?.join("\n")).not.toContain("/repo/file.ts");
	expect(picker().items.find((item) => item.value === "confirm")?.label).toBe(
		"Rewind history only",
	);
});

test("confirmation repeats the exact preview target, restores the prompt and reloads only after success", async () => {
	h.server.respondWith("sessions.rewind", filesPreview);
	await h.run("/rewind --files");
	await chooseUser();
	h.server.respondWith("sessions.rewind", {
		...filesPreview,
		partialRestore: false,
		leafId: "a1",
		restoredPaths: ["/repo/file.ts"],
	});
	await picker().onSelect(picker().items.find((item) => item.value === "confirm")!);
	const requests = h.server.requestsFor("sessions.rewind");
	expect(requests[0].params).toEqual({
		sessionKey: "s",
		cwd: "/repo",
		entryId: "u2",
		restoreFiles: true,
		allowPartialRestore: false,
		dryRun: true,
	});
	expect(requests[1].params).toEqual({
		sessionKey: "s",
		cwd: "/repo",
		entryId: "u2",
		restoreFiles: true,
		allowPartialRestore: false,
		dryRun: false,
		confirmationToken: preview.confirmationToken,
	});
	expect(h.host.draft).toBe("second prompt");
	expect(resets).toEqual(["s"]);
	expect(reloads).toEqual(["s"]);
	expect(h.host.deliveries).toEqual([]);
});

test("stale confirmation never clears the local transcript or draft", async () => {
	await h.run("/rewind");
	await chooseUser();
	h.server.failWith("sessions.rewind", "STALE_CONFIRMATION", "preview no longer matches");
	await picker().onSelect(picker().items.find((item) => item.value === "confirm")!);
	expect(h.host.draft).toBe("keep my draft");
	expect(resets).toEqual([]);
	expect(reloads).toEqual([]);
	expect(h.host.text).toContain("STALE_CONFIRMATION");
});

test("switching sessions after preview cannot confirm a stale modal against the new focus", async () => {
	await h.run("/rewind");
	await chooseUser();
	h.store.setFocused("other");
	await picker().onSelect(picker().items.find((item) => item.value === "confirm")!);
	expect(h.server.requestsFor("sessions.rewind")).toHaveLength(1);
	expect(resets).toEqual([]);
});

async function choose(value: string): Promise<void> {
	await picker().onSelect(picker().items.find((item) => item.value === value)!);
}

async function previewPartial(): Promise<void> {
	h.server.respondWith("sessions.rewind", blockedPreview);
	await h.run("/rewind --files");
	await chooseUser();
	h.server.respondWith("sessions.rewind", partialPreview);
	await choose("allow-partial");
}

test("shell effects require explicit consent followed by a fresh preview and exact confirmation", async () => {
	h.server.respondWith("sessions.rewind", blockedPreview);
	await h.run("/rewind --files");
	await chooseUser();
	expect(picker().items.map((item) => item.value)).toEqual(["cancel", "allow-partial", "inspect"]);
	expect(picker().detail?.join("\n")).toContain(
		"restore 1 checkpointed files; effects of 2 shell commands are not reverted",
	);
	for (const command of blockedPreview.unrestorableCommands) {
		expect(picker().detail?.join("\n")).toContain(command);
		expect(h.host.text).toContain(command);
	}
	// No hidden confirm action may bypass explicit consent.
	await picker().onSelect({ value: "confirm", label: "confirm" });
	expect(h.server.requestsFor("sessions.rewind")).toHaveLength(1);
	h.server.respondWith("sessions.rewind", partialPreview);
	await choose("allow-partial");
	const requests = h.server.requestsFor("sessions.rewind");
	expect(requests.map((request) => request.params)).toEqual([
		{
			sessionKey: "s",
			cwd: "/repo",
			entryId: "u2",
			restoreFiles: true,
			allowPartialRestore: false,
			dryRun: true,
		},
		{
			sessionKey: "s",
			cwd: "/repo",
			entryId: "u2",
			restoreFiles: true,
			allowPartialRestore: true,
			dryRun: true,
		},
	]);
	expect(picker().items[0].value).toBe("cancel");
	expect(picker().items.find((item) => item.value === "confirm")?.label).toContain(
		"shell effects remain",
	);
	expect(resets).toEqual([]);
	expect(h.host.draft).toBe("keep my draft");
	h.server.respondWith("sessions.rewind", partialResult);
	await choose("confirm");
	expect(h.server.requestsFor("sessions.rewind").at(-1)?.params).toEqual({
		sessionKey: "s",
		cwd: "/repo",
		entryId: "u2",
		restoreFiles: true,
		allowPartialRestore: true,
		dryRun: false,
		confirmationToken: partialPreview.confirmationToken,
	});
	expect(resets).toEqual(["s"]);
	expect(reloads).toEqual(["s"]);
	expect(h.host.draft).toBe("second prompt");
	expect(h.host.last?.text).toContain("effects of 2 shell commands are not reverted");
	expect(h.host.deliveries).toEqual([]);
});

test.each(["cancel", "inspect"])("partial preview %s never confirms", async (choice) => {
	await previewPartial();
	await choose(choice);
	expect(h.server.requestsFor("sessions.rewind")).toHaveLength(2);
	for (const request of h.server.requestsFor("sessions.rewind")) {
		expect(request.params).toMatchObject({ dryRun: true });
	}
	expect(h.host.draft).toBe("keep my draft");
	expect(resets).toEqual([]);
	expect(reloads).toEqual([]);
});

test("revoking partial consent re-previews with false and requires a new consent token", async () => {
	await previewPartial();
	h.server.respondWith("sessions.rewind", {
		...blockedPreview,
		confirmationToken: "revoked-snapshot-token",
	});
	await choose("require-complete");
	expect(h.server.requestsFor("sessions.rewind").at(-1)?.params).toMatchObject({
		allowPartialRestore: false,
		dryRun: true,
	});
	expect(picker().items.map((item) => item.value)).toEqual(["cancel", "allow-partial", "inspect"]);
	h.server.respondWith("sessions.rewind", {
		...partialPreview,
		confirmationToken: "renewed-partial-token",
	});
	await choose("allow-partial");
	h.server.respondWith("sessions.rewind", {
		...partialResult,
		confirmationToken: "renewed-partial-token",
	});
	await choose("confirm");
	expect(h.server.requestsFor("sessions.rewind").at(-1)?.params).toMatchObject({
		allowPartialRestore: true,
		confirmationToken: "renewed-partial-token",
		dryRun: false,
	});
	expect(resets).toEqual(["s"]);
});

test("backend eligibility, not a command-name special case, governs partial restoration", async () => {
	h.server.respondWith("sessions.rewind", {
		...blockedPreview,
		canAllowPartialRestore: false,
	});
	await h.run("/rewind --files");
	await chooseUser();
	expect(picker().items.map((item) => item.value)).toEqual(["cancel", "inspect"]);
	expect(h.host.text).toContain("daemon cannot safely restore these effects");
	expect(h.server.requestsFor("sessions.rewind")).toHaveLength(1);
});

test("bounded previews with undisplayed shell commands cannot authorize restoration", async () => {
	h.server.respondWith("sessions.rewind", {
		...blockedPreview,
		unrestorableCommandCount: 101,
	});
	await h.run("/rewind --files");
	await chooseUser();
	expect(picker().items.map((item) => item.value)).toEqual(["cancel", "inspect"]);
	expect(h.host.text).toContain("effects of 101 shell commands are not reverted");
	expect(h.host.text).toContain("not all shell commands fit in this preview");
});

test("legacy previews remain readable but cannot authorize partial restoration", async () => {
	h.server.respondWith("sessions.rewind", {
		sessionKey: preview.sessionKey,
		sessionId: preview.sessionId,
		entryId: preview.entryId,
		confirmationToken: preview.confirmationToken,
		prompt: preview.prompt,
		promptContainsNonText: preview.promptContainsNonText,
		discardedMessages: preview.discardedMessages,
		restorePaths: preview.restorePaths,
		unrestorableTools: ["bash"],
	});
	await h.run("/rewind --files");
	await chooseUser();
	expect(picker().items.map((item) => item.value)).toEqual(["cancel", "inspect"]);
	expect(h.host.text).toContain("does not provide the command details required");
	await h.run("/rewind");
	await chooseUser();
	expect(picker().items.some((item) => item.value === "confirm")).toBe(true);
	expect(picker().detail?.join("\n")).not.toContain("/repo/file.ts");
});

test.each([
	{ allowPartialRestore: false },
	{ allowPartialRestore: undefined },
	{ restoreFiles: false },
	{ restoreFiles: undefined },
	{ unrestorableCommands: undefined, unrestorableCommandCount: undefined },
])("partial re-preview refuses missing or changed intent: %j", async (changed) => {
	h.server.respondWith("sessions.rewind", blockedPreview);
	await h.run("/rewind --files");
	await chooseUser();
	const before = h.host.pickers.length;
	h.server.respondWith("sessions.rewind", { ...partialPreview, ...changed });
	await choose("allow-partial");
	expect(h.host.pickers).toHaveLength(before);
	expect(h.host.text).toContain("INVALID_RESPONSE");
	expect(h.host.draft).toBe("keep my draft");
	expect(resets).toEqual([]);
});

test.each([
	{ confirmationToken: "wrong-token" },
	{ allowPartialRestore: false },
	{ restoreFiles: false },
	{ partialRestore: false },
	{ entryId: "u1" },
	{ sessionId: "other-native-session" },
	{ prompt: "different prompt" },
	{ restoredPaths: [] },
	{ restoredPaths: ["/repo/unpreviewed.ts"] },
	{ unrestorableCommands: ["different shell command", "printf second"] },
	{ unrestorableCommandCount: 1 },
	{ unrestorableTools: [] },
])("unmatched partial receipt cannot reset local state: %j", async (changed) => {
	await previewPartial();
	h.server.respondWith("sessions.rewind", { ...partialResult, ...changed });
	await choose("confirm");
	expect(h.host.text).toContain("rewind outcome could not be verified");
	expect(h.host.draft).toBe("keep my draft");
	expect(resets).toEqual([]);
	expect(reloads).toEqual([]);
});

test.each(["stale_confirmation", "checkpoint_missing", "partial_restore_unreviewable"])(
	"partial refusal %s preserves the draft and transcript",
	async (reason) => {
		await previewPartial();
		h.server.failWith("sessions.rewind", "CONFLICT", "refused", { reason });
		await choose("confirm");
		expect(h.host.text).toContain(`CONFLICT: ${reason}`);
		expect(h.host.draft).toBe("keep my draft");
		expect(resets).toEqual([]);
		expect(reloads).toEqual([]);
	},
);

test("session switching before partial consent cannot request another preview", async () => {
	h.server.respondWith("sessions.rewind", blockedPreview);
	await h.run("/rewind --files");
	await chooseUser();
	h.store.setFocused("other");
	await choose("allow-partial");
	expect(h.server.requestsFor("sessions.rewind")).toHaveLength(1);
	expect(h.host.text).toContain("focused session changed");
});

test("history-only receipts cannot claim file restoration", async () => {
	await h.run("/rewind");
	await chooseUser();
	h.server.respondWith("sessions.rewind", {
		...preview,
		leafId: "a1",
		restoredPaths: preview.restorePaths,
		partialRestore: false,
	});
	await choose("confirm");
	expect(h.host.text).toContain("rewind outcome could not be verified");
	expect(h.host.draft).toBe("keep my draft");
	expect(resets).toEqual([]);
});

test("history-only confirmation leaves files untouched and recalls only the confirmed prompt", async () => {
	h.server.respondWith("sessions.rewind", { ...blockedPreview, restoreFiles: false });
	await h.run("/rewind");
	await chooseUser();
	expect(picker().items.map((item) => item.value)).toEqual(["cancel", "confirm", "inspect"]);
	expect(h.host.text).not.toContain("restore:");
	expect(h.host.text).not.toContain("/repo/file.ts");
	h.server.respondWith("sessions.rewind", {
		...blockedPreview,
		restoreFiles: false,
		partialRestore: false,
		restoredPaths: [],
		leafId: "a1",
	});
	await choose("confirm");
	expect(resets).toEqual(["s"]);
	expect(reloads).toEqual(["s"]);
	expect(h.host.last?.text).toContain("history only · files unchanged");
	expect(h.host.last?.text).not.toContain("file(s) restored");
});

test("full preview retains every bounded command when modal details are abbreviated", async () => {
	const commands = Array.from({ length: 8 }, (_, index) => `printf command-${index}`);
	h.server.respondWith("sessions.rewind", {
		...blockedPreview,
		unrestorableCommands: commands,
		unrestorableCommandCount: commands.length,
	});
	await h.run("/rewind --files");
	await chooseUser();
	expect(picker().detail?.join("\n")).toContain("More preview details in transcript");
	for (const command of commands) expect(h.host.text).toContain(command);
	await choose("inspect");
	expect(h.server.requestsFor("sessions.rewind")).toHaveLength(1);
	expect(h.host.draft).toBe("keep my draft");
});

test("a failed partial re-preview never confirms or changes local state", async () => {
	h.server.respondWith("sessions.rewind", blockedPreview);
	await h.run("/rewind --files");
	await chooseUser();
	h.server.failWith("sessions.rewind", "CONFLICT", "refused", { reason: "checkpoint_missing" });
	await choose("allow-partial");
	expect(h.server.requestsFor("sessions.rewind")).toHaveLength(2);
	for (const request of h.server.requestsFor("sessions.rewind")) {
		expect(request.params).toMatchObject({ dryRun: true });
	}
	expect(h.host.text).toContain("CONFLICT: checkpoint_missing");
	expect(resets).toEqual([]);
	expect(reloads).toEqual([]);
	expect(h.host.draft).toBe("keep my draft");
});

test("explicit partial consent accurately previews and confirms zero checkpointed files", async () => {
	h.server.respondWith("sessions.rewind", { ...blockedPreview, restorePaths: [] });
	await h.run("/rewind --files");
	await chooseUser();
	h.server.respondWith("sessions.rewind", { ...partialPreview, restorePaths: [] });
	await choose("allow-partial");
	expect(picker().detail?.join("\n")).toContain(
		"restore 0 checkpointed files; effects of 2 shell commands are not reverted",
	);
	h.server.respondWith("sessions.rewind", { ...partialResult, restoredPaths: [] });
	await choose("confirm");
	expect(resets).toEqual(["s"]);
	expect(h.host.last?.text).toContain("0 checkpointed file(s) restored");
	expect(h.host.last?.text).toContain("effects of 2 shell commands are not reverted");
});

test("name persists server metadata and mirrors the confirmed title", async () => {
	h.server.respondWith("sessions.metadata.patch", { success: true, metadata: { titleBytes: 12 } });
	await h.run("/name Review parser");
	expect(h.server.requestsFor("sessions.metadata.patch")[0].params).toEqual({
		sessionKey: "s",
		title: "Review parser",
	});
	expect(h.store.focused.title).toBe("Review parser");
	h.server.failWith("sessions.metadata.patch", "FORBIDDEN", "denied");
	await h.run("/name Not accepted");
	expect(h.store.focused.title).toBe("Review parser");
});

test("names a fresh local session without sending a model prompt", async () => {
	const sessionKey = "agent:default:tui:local:dm:fresh";
	h.store.setFocused(sessionKey);
	h.server.respondWith("sessions.create", { sessionKey, sessionId: "native-fresh", created: true });
	h.server.respondWith("sessions.metadata.patch", { success: true, metadata: { titleBytes: 5 } });
	await h.run("/name Ready");
	expect(h.server.requestsFor("sessions.create")[0].params).toEqual({ sessionKey, cwd: "/repo" });
	expect(h.store.focused.title).toBe("Ready");
	expect(h.server.requestsFor("chat.send")).toHaveLength(0);
});

test("a refused empty-session creation never claims a title or patches metadata", async () => {
	h.store.setFocused("agent:default:tui:local:dm:fresh");
	h.server.failWith("sessions.create", "CONFLICT", "workspace differs");
	await h.run("/name Not accepted");
	expect(h.store.focused.title).toBeUndefined();
	expect(h.server.requestsFor("sessions.metadata.patch")).toHaveLength(0);
	expect(h.server.requestsFor("chat.send")).toHaveLength(0);
});
