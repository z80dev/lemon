import { afterEach, beforeEach, expect, test } from "bun:test";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import { agentHubCommand } from "../../src/commands/agent-hub.ts";
import type { CommandContext, OverlayHost } from "../../src/commands/registry.ts";
import type { ChatHistoryParams, ChatHistoryResult } from "../../src/protocol/types.ts";
import { TaskStore } from "../../src/store/task-store.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";

beforeEach(() => initTheme({ colorLevel: 0 }));
afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

function open(reply: (params: ChatHistoryParams) => ChatHistoryResult) {
	const store = new TaskStore();
	store.upsert(
		"parent",
		[{ taskId: "t1", sessionId: "child-native", status: "completed", description: "Child" }],
		0,
	);
	const calls: ChatHistoryParams[] = [];
	const shown: { hub?: Component } = {};
	const host: OverlayHost = {
		close: () => {},
		repaint: () => {},
		rows: () => 30,
		columns: () => 100,
		tui: undefined as never,
	};
	const ctx = {
		session: { key: "parent" },
		cwd: "/work",
		ui: {
			notice: () => {},
			presentOverlay: (build: (host: OverlayHost) => Component) => {
				shown.hub = build(host);
			},
			taskFeed: (key: string) => ({
				rows: () => store.tree(key),
				subscribe: (listener: () => void) =>
					store.events.on("changed", ({ sessionKey }) => {
						if (sessionKey === key) listener();
					}),
			}),
		},
		methods: {
			supports: () => true,
			chatHistory: async (params: ChatHistoryParams) => {
				calls.push(params);
				return reply(params);
			},
		},
	} as unknown as CommandContext;
	agentHubCommand.run(ctx, []);
	const presented = shown.hub;
	if (!presented?.handleInput) throw new Error("/hub did not present an interactive overlay");
	const handleInput = presented.handleInput.bind(presented);
	return { hub: presented, press: (data: string) => handleInput(data), calls };
}

test("a transcript is requested under the parent's key with the child's session id", async () => {
	const { hub, press, calls } = open((params) => ({
		sessionKey: params.sessionKey,
		childSessionId: params.childSessionId,
		messages: [{ id: "1", role: "assistant", content: "child says hi", timestampMs: null }],
	}));
	press("\r");
	await Bun.sleep(20);
	expect(calls).toEqual([
		{
			sessionKey: "parent",
			childSessionId: "child-native",
			limit: 200,
			includeFullText: true,
		},
	]);
	expect(hub.render(100).join("\n")).toContain("child says hi");
	hub.dispose?.();
});

test("a daemon that ignores childSessionId never shows the parent's history as the child's", async () => {
	const { hub, press } = open((params) => ({
		sessionKey: params.sessionKey,
		messages: [{ id: "1", role: "assistant", content: "PARENT TEXT", timestampMs: null }],
	}));
	press("\r");
	await Bun.sleep(20);
	const text = hub.render(100).join("\n");
	expect(text).not.toContain("PARENT TEXT");
	expect(text).toContain("cannot read child transcripts");
	hub.dispose?.();
});
