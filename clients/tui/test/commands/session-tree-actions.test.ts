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

test("tree rows show labels and hide bookkeeping label entries", async () => {
	await h.run("/tree");
	expect(picker().items.map((item) => item.value)).toEqual(["u1", "a1", "u2", "a2", "old"]);
	expect(picker().items.find((item) => item.value === "old")?.label).toContain("[try B]");
});

test("actions depend on the entry: other branch, same branch, current leaf", async () => {
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

test("switching resets and reloads the session and recalls a user prompt into an empty draft", async () => {
	h.server.respondWith("sessions.navigate", {
		sessionKey: "s",
		sessionId: "native-s",
		entryId: "old",
		leafId: "a1",
		prompt: "abandoned prompt, full text",
		summarizing: false,
	});
	await choose(await openActions("old"), "switch");
	expect(h.server.requestsFor("sessions.navigate")[0].params).toEqual({
		sessionKey: "s",
		cwd: "/repo",
		entryId: "old",
		summarize: false,
	});
	expect(resets).toEqual(["s"]);
	expect(reloads).toEqual(["s"]);
	expect(h.host.draft).toBe("abandoned prompt, full text");
	expect(h.host.text).toContain("switched active branch to old");
});

test("switching keeps an existing draft and reports the selected prompt instead", async () => {
	h.server.respondWith("sessions.navigate", {
		sessionKey: "s",
		sessionId: "native-s",
		entryId: "old",
		leafId: "a1",
		prompt: "abandoned prompt, full text",
		summarizing: false,
	});
	const actions = await openActions("old");
	h.host.draft = "my unfinished thought";
	await choose(actions, "switch");
	expect(h.host.draft).toBe("my unfinished thought");
	expect(h.host.text).toContain("abandoned prompt, full text");
});

test("summarizing switch asks for the summary and reports when it was skipped", async () => {
	h.server.respondWith("sessions.navigate", {
		sessionKey: "s",
		sessionId: "native-s",
		entryId: "old",
		leafId: "old",
		prompt: null,
		summarizing: true,
	});
	await choose(await openActions("old"), "switch-summarize");
	expect(h.server.requestsFor("sessions.navigate")[0].params).toMatchObject({ summarize: true });
	expect(h.host.text).toContain("being summarized in the background");

	h.server.respondWith("sessions.navigate", {
		sessionKey: "s",
		sessionId: "native-s",
		entryId: "old",
		leafId: "old",
		prompt: null,
		summarizing: false,
	});
	await choose(await openActions("old"), "switch-summarize");
	expect(h.host.text).toContain("summary skipped");
});

test("a busy session refuses to switch without calling the daemon", async () => {
	const actions = await openActions("old");
	h.store.focused.busy = true;
	await choose(actions, "switch");
	expect(h.server.requestsFor("sessions.navigate")).toHaveLength(0);
	expect(h.host.text).toContain("stop the current run before switching branches");
	expect(resets).toEqual([]);
});

test("a daemon refusal leaves the local transcript and draft alone", async () => {
	h.server.failWith("sessions.navigate", "CONFLICT", "busy", { reason: "busy" });
	const actions = await openActions("old");
	h.host.draft = "keep me";
	await choose(actions, "switch");
	expect(resets).toEqual([]);
	expect(reloads).toEqual([]);
	expect(h.host.draft).toBe("keep me");
	expect(h.host.text).toContain("did not complete (CONFLICT: busy)");
});

test("labels are set with argv forms and cleared from the picker", async () => {
	h.server.respondWith("sessions.label", {
		sessionKey: "s",
		sessionId: "native-s",
		entryId: "u2",
		label: "good  idea",
	});
	await h.run("/tree label u2 good  idea");
	expect(h.server.requestsFor("sessions.label")[0].params).toEqual({
		sessionKey: "s",
		cwd: "/repo",
		entryId: "u2",
		label: "good  idea",
	});
	expect(h.host.text).toContain("labelled u2: good  idea");

	h.server.respondWith("sessions.label", {
		sessionKey: "s",
		sessionId: "native-s",
		entryId: "old",
		label: null,
	});
	await choose(await openActions("old"), "unlabel");
	expect(h.server.requestsFor("sessions.label")[1].params).toMatchObject({
		entryId: "old",
		label: null,
	});
	expect(h.host.text).toContain("cleared the label of old");

	await h.run("/tree unlabel old");
	expect(h.server.requestsFor("sessions.label")[2].params).toMatchObject({ label: null });
});

test("Set label prefills the composer only when it is empty", async () => {
	await choose(await openActions("u2"), "label");
	expect(h.host.draft).toBe("/tree label u2 ");
	const actions = await openActions("u2");
	h.host.draft = "typing something";
	await choose(actions, "label");
	expect(h.host.draft).toBe("typing something");
	expect(h.host.text).toContain("/tree label u2 <text>");
});

test("fork from here sends the entry id and opens the child", async () => {
	h.server.respondWith("sessions.fork", { sessionKey: "child", sourceSessionKey: "s" });
	await choose(await openActions("u2"), "fork");
	expect(h.server.requestsFor("sessions.fork")[0].params).toEqual({
		sessionKey: "s",
		cwd: "/repo",
		entryId: "u2",
	});
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
