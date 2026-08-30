import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { AppShell, canonicalProfileId } from "../../src/app.ts";
import { FakeControlPlane } from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal } from "../helpers/memory-terminal.ts";

const teardown: Array<() => void> = [];

const profile = {
	id: "operator",
	name: "Operator",
	model: "openai:gpt-5",
	node: "newphy",
	canonicalSessionKey: "agent:operator:main",
	availability: "online",
};

beforeEach(() => initTheme({ colorLevel: 3 }));

afterEach(() => {
	while (teardown.length > 0) teardown.pop()?.();
	resetTheme();
	invalidateThemeAdapters();
});

async function boot() {
	const server = await FakeControlPlane.start();
	teardown.push(() => server.stop());
	server.respondWith("profiles.get", { profile });
	server.respondWith("profiles.roster", { profiles: [profile], count: 1 });
	server.onMethod("profile.chat", (params: Record<string, unknown>) => ({
		runId: `profile-run-${server.requestsFor("profile.chat").length}`,
		profileId: "operator",
		sessionKey: "agent:operator:main",
		node: "newphy",
		summary: { queueMode: params.queueMode ?? "collect" },
	}));
	server.onMethod("chat.send", (params: Record<string, unknown>) => ({
		runId: "generic-run",
		sessionKey: params.sessionKey,
	}));

	const terminal = new MemoryTerminal();
	const client = new ControlPlaneClient({
		url: server.url,
		socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
	});
	const app = new AppShell({
		url: server.url,
		client,
		terminal,
		sessionKey: "tui-start",
		readBranch: async () => "main",
	});
	teardown.push(() => app.stop());
	await app.start();
	return { app, server };
}

describe("profile chat routing in the real TUI shell", () => {
	test("opening a profile makes ordinary prompts use profile.chat", async () => {
		const { app, server } = await boot();

		await app.submit("/profile open operator");
		expect(app.sessionKey).toBe("agent:operator:main");

		await app.submit("inspect the release");

		expect(server.requestsFor("profile.chat")[0]?.params).toEqual({
			id: "operator",
			prompt: "inspect the release",
		});
		expect(server.requestsFor("chat.send")).toHaveLength(0);
	});

	test("busy corrections preserve queue mode on profile.chat", async () => {
		const { app, server } = await boot();
		await app.submit("/profile open operator");
		await app.submit("start the review");

		await app.sendPrompt("focus on the failing proof", { mode: "steer" });

		expect(server.requestsFor("profile.chat")[1]?.params).toEqual({
			id: "operator",
			prompt: "focus on the failing proof",
			queueMode: "steer",
		});
		expect(server.requestsFor("chat.send")).toHaveLength(0);
	});

	test("an unmanaged canonical agent key falls back only after profiles.get says not found", async () => {
		const { app, server } = await boot();
		server.failWith("profiles.get", "NOT_FOUND", "Profile not found");
		await app.sessions.switch("agent:ordinary:main");

		await app.submit("ordinary agent prompt");

		expect(server.requestsFor("profiles.get").at(-1)?.params).toEqual({ id: "ordinary" });
		expect(server.requestsFor("profile.chat")).toHaveLength(0);
		expect(server.requestsFor("chat.send")[0]?.params).toEqual({
			sessionKey: "agent:ordinary:main",
			prompt: "ordinary agent prompt",
		});
	});

	test("profile deletion between preflight and chat fails closed", async () => {
		const { app, server } = await boot();
		server.failWith("profile.chat", "NOT_FOUND", "Profile was deleted");
		await app.sessions.switch("agent:operator:main");

		await app.submit("do not reroute this prompt");

		expect(server.requestsFor("profiles.get").at(-1)?.params).toEqual({ id: "operator" });
		expect(server.requestsFor("profile.chat")[0]?.params).toEqual({
			id: "operator",
			prompt: "do not reroute this prompt",
		});
		expect(server.requestsFor("chat.send")).toHaveLength(0);
	});

	test("canonical key parsing rejects arbitrary and nested session keys", () => {
		expect(canonicalProfileId("agent:operator:main")).toBe("operator");
		expect(canonicalProfileId("agent:operator:main:sub:child")).toBeUndefined();
		expect(canonicalProfileId("/tmp/workspace")).toBeUndefined();
		expect(canonicalProfileId("agent:Upper:main")).toBeUndefined();
	});
});
