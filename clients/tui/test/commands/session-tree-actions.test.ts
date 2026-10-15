import { afterEach, beforeEach, expect, test } from "bun:test";
import type { CommandHost, PickerSpec } from "../../src/commands/registry.ts";
import type { SessionTreeResult } from "../../src/protocol/session-tree.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

let h: Harness;
let resets: string[];
let reloads: string[];
let opened: string[];

const tree: SessionTreeResult = {
	sessionKey: "s",
	sessionId: "native-s",
	leafId: "a2",
	offset: 0,
	totalEntries: 6,
	hasMore: false,
	branches: [
		{ leafId: "a2", active: true },
		{ leafId: "old", active: false },
	],
	entries: [
		{ id: "u1", parentId: null, type: "message", role: "user", text: "first prompt" },
		{ id: "a1", parentId: "u1", type: "message", role: "assistant", text: "first answer" },
		{ id: "u2", parentId: "a1", type: "message", role: "user", text: "second prompt" },
		{ id: "a2", parentId: "u2", type: "message", role: "assistant", text: "second answer" },
		{
			id: "old",
			parentId: "a1",
			type: "message",
			role: "user",
			text: "abandoned prompt",
			label: "try B",
		},
		{ id: "lbl", parentId: "a2", type: "label", text: "" },
	].map((entry) => ({
		isActive: !["old"].includes(entry.id),
		isLeaf: ["a2", "old", "lbl"].includes(entry.id),
		rewindable: entry.role === "user",
		...entry,
	})),
};

beforeEach(async () => {
	h = await createHarness({
		sessionKey: "s",
		cwd: "/repo",
		methods: [
			"chat.history",
			"sessions.tree",
			"sessions.navigate",
			"sessions.label",
			"sessions.fork",
		],
	});
	resets = [];
	reloads = [];
	opened = [];
	Object.assign(h.host, {
		resetSession: (key: string) => {
			resets.push(key);
		},
		reloadSession: async (key: string) => {
			reloads.push(key);
		},
		openFork: async (key: string) => {
			opened.push(key);
		},
	});
	h.server.respondWith("sessions.tree", tree);
});
afterEach(() => h.stop());

function picker(): PickerSpec {
	return h.host.pickers.at(-1)!;
}

async function openActions(entryId: string): Promise<PickerSpec> {
	await h.run("/tree");
	const rows = picker();
	await rows.onSelect(rows.items.find((item) => item.value === entryId)!);
	return picker();
}

async function choose(actions: PickerSpec, value: string): Promise<void> {
	await actions.onSelect(actions.items.find((item) => item.value === value)!);
}

test("actions depend on the entry: other branch, same branch, current leaf", async () => {
	await h.run("/tree");
	// Bookkeeping label entries are hidden from the picker.
	expect(picker().items.map((item) => item.value)).toEqual(["u1", "a1", "u2", "a2", "old"]);

	const other = await openActions("old");
	expect(other.items.map((item) => item.value)).toEqual([
		"inspect",
		"switch",
		"switch-summarize",
		"label",
		"unlabel",
		"fork",
	]);
	const sameBranch = await openActions("u2");
	expect(sameBranch.items.map((item) => item.value)).toEqual([
		"inspect",
		"switch",
		"label",
		"fork",
	]);
	const leaf = await openActions("a2");
	expect(leaf.items.map((item) => item.value)).toEqual(["inspect", "label", "fork"]);
});

function receipt(overrides: Record<string, unknown> = {}) {
	return {
		sessionKey: "s",
		sessionId: "native-s",
		entryId: "old",
		leafId: "a1",
		prompt: "abandoned prompt, full text",
		summarizing: false,
		...overrides,
	};
}

test("switching resets and reloads the session and recalls a user prompt into an empty draft", async () => {
	h.server.respondWith("sessions.navigate", receipt());
	await choose(await openActions("old"), "switch");
	expect(h.server.requestsFor("sessions.navigate")[0].params).toMatchObject({ entryId: "old" });
	expect(resets).toEqual(["s"]);
	expect(reloads).toEqual(["s"]);
	expect(h.host.draft).toBe("abandoned prompt, full text");
});

test("switching keeps an existing draft and reports the selected prompt instead", async () => {
	h.server.respondWith("sessions.navigate", receipt());
	const actions = await openActions("old");
	h.host.draft = "my unfinished thought";
	await choose(actions, "switch");
	expect(h.host.draft).toBe("my unfinished thought");
	expect(h.host.text).toContain("abandoned prompt, full text");
});

test("a busy session refuses to switch without calling the daemon", async () => {
	const actions = await openActions("old");
	h.store.focused.busy = true;
	await choose(actions, "switch");
	expect(h.server.requestsFor("sessions.navigate")).toHaveLength(0);
	expect(resets).toEqual([]);
});

test("a daemon refusal or a receipt for another entry leaves the local transcript and draft alone", async () => {
	h.server.failWith("sessions.navigate", "CONFLICT", "busy", { reason: "busy" });
	const actions = await openActions("old");
	h.host.draft = "keep me";
	await choose(actions, "switch");

	h.server.respondWith("sessions.navigate", receipt({ entryId: "u1", leafId: "u1" }));
	await choose(actions, "switch");

	expect(resets).toEqual([]);
	expect(reloads).toEqual([]);
	expect(h.host.draft).toBe("keep me");
});

test("labels are set from argv and cleared from the picker", async () => {
	h.server.respondWith("sessions.label", {
		sessionKey: "s",
		sessionId: "native-s",
		entryId: "u2",
		label: "good  idea",
	});
	await h.run("/tree label u2 good  idea");
	expect(h.server.requestsFor("sessions.label")[0].params).toMatchObject({
		entryId: "u2",
		label: "good  idea",
	});

	await choose(await openActions("old"), "unlabel");
	expect(h.server.requestsFor("sessions.label")[1].params).toMatchObject({
		entryId: "old",
		label: null,
	});

	await h.run("/tree label u2");
	await h.run("/tree bogus");
	expect(h.server.requestsFor("sessions.label")).toHaveLength(2);
});

test("Set label prefills the composer only when it is empty", async () => {
	await choose(await openActions("u2"), "label");
	expect(h.host.draft).toBe("/tree label u2 ");
	const actions = await openActions("u2");
	h.host.draft = "typing something";
	await choose(actions, "label");
	expect(h.host.draft).toBe("typing something");
});

test("fork from here sends the entry id and opens the child", async () => {
	h.server.respondWith("sessions.fork", { sessionKey: "child", sourceSessionKey: "s" });
	await choose(await openActions("u2"), "fork");
	expect(h.server.requestsFor("sessions.fork")[0].params).toMatchObject({ entryId: "u2" });
	expect(opened).toEqual(["child"]);
});

test("older daemons without the new methods only offer inspection", async () => {
	h.stop();
	h = await createHarness({ sessionKey: "s", cwd: "/repo", methods: ["sessions.tree"] });
	(h.host as CommandHost).openFork = async () => {};
	h.server.respondWith("sessions.tree", tree);
	const actions = await openActions("old");
	expect(actions.items.map((item) => item.value)).toEqual(["inspect"]);
});
