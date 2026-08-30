/**
 * Every command that reaches the daemon, against the fake control plane:
 * the right method, with the right params, and a readable notice back.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

let harness: Harness;

beforeEach(async () => {
	initTheme({ colorLevel: 3 });
	harness = await createHarness({ sessionKey: "tui-session", cwd: "/workspace/project" });
});

afterEach(() => {
	harness.stop();
	resetTheme();
	invalidateThemeAdapters();
});

describe("routing commands", () => {
	beforeEach(() => {
		harness.server.respondWith("sessions.patch", { success: true });
		harness.server.respondWith("models.list", {
			models: [
				{
					id: "claude-sonnet-4",
					provider: "anthropic",
					name: "Claude Sonnet 4",
					contextWindow: 200000,
					supportsThinking: true,
					supportsVision: false,
				},
				{ id: "gpt-4o", provider: "openai", name: "GPT-4o", contextWindow: 128000 },
			],
		});
	});

	test("/model <id> patches the session and mirrors it locally", async () => {
		await harness.run("/model claude-sonnet-4");
		const frame = harness.server.requestsFor("sessions.patch")[0];
		expect(frame.params).toEqual({ sessionKey: "tui-session", model: "claude-sonnet-4" });
		expect(harness.store.focused.model).toBe("claude-sonnet-4");
		expect(harness.host.text).toContain("claude-sonnet-4");
	});

	test("/model rejects an id the daemon does not know", async () => {
		await harness.run("/model not-a-model");
		expect(harness.server.requestsFor("sessions.patch")).toHaveLength(0);
		expect(harness.host.last?.level).toBe("error");
	});

	test("/model with no argument opens the picker", async () => {
		await harness.run("/model");
		expect(harness.host.modelPickerOpens).toBe(1);
	});

	test("/think validates the level before sending", async () => {
		await harness.run("/think high");
		expect(harness.server.requestsFor("sessions.patch")[0].params).toEqual({
			sessionKey: "tui-session",
			thinkingLevel: "high",
		});
		await harness.run("/think ludicrous");
		expect(harness.server.requestsFor("sessions.patch")).toHaveLength(1);
		expect(harness.host.last?.text).toContain("unknown level");
	});

	test("/reasoning is the Hermes alias for /think", async () => {
		await harness.run("/reasoning high");
		expect(harness.server.requestsFor("sessions.patch")[0].params).toEqual({
			sessionKey: "tui-session",
			thinkingLevel: "high",
		});
	});

	test("does not register /engine while retaining native model controls", async () => {
		expect(harness.registry.has("engine")).toBe(false);
		expect(harness.registry.has("model")).toBe(true);
		expect(harness.registry.has("sessions")).toBe(true);
		expect(harness.registry.has("session")).toBe(true);
		expect(harness.registry.has("resume")).toBe(true);

		await harness.run("/engine codex");
		expect(harness.server.requestsFor("sessions.patch")).toHaveLength(0);
		expect(harness.host.last?.level).toBe("error");
		expect(harness.host.last?.text).toContain("unknown command /engine");
	});

	test("/toolpolicy sends the profile the daemon parses", async () => {
		await harness.run("/toolpolicy read_only");
		expect(harness.server.requestsFor("sessions.patch")[0].params).toEqual({
			sessionKey: "tui-session",
			toolPolicy: { profile: "read_only" },
		});
	});

	test("/toolpolicy lists the profiles when asked with no argument", async () => {
		await harness.run("/toolpolicy");
		expect(harness.host.text).toContain("safe_mode");
		expect(harness.server.requestsFor("sessions.patch")).toHaveLength(0);
	});
});

describe("session heartbeat", () => {
	const activeHeartbeat = {
		sessionKey: "tui-session",
		action: "status",
		heartbeat: {
			configured: true,
			status: "active",
			prompt: "check CI and open reviews",
			intervalSeconds: 600,
			fireCount: 2,
			nextInSeconds: 599,
		},
	};

	test("/heartbeat every sets a recurring same-session prompt", async () => {
		harness.server.respondWith("sessions.heartbeat", activeHeartbeat);

		await harness.run("/heartbeat every 10m check CI and open reviews");

		expect(harness.server.requestsFor("sessions.heartbeat")[0].params).toEqual({
			sessionKey: "tui-session",
			action: "set",
			prompt: "check CI and open reviews",
			intervalSeconds: 600,
		});
		expect(harness.host.text).toContain("heartbeat set");
		expect(harness.host.text).toContain("every 10m");
		expect(harness.host.text).toContain("fired 2×");
	});

	test("/hb is the status alias and lifecycle actions preserve the session key", async () => {
		harness.server.respondWith("sessions.heartbeat", activeHeartbeat);

		await harness.run("/hb");
		await harness.run("/heartbeat pause");
		await harness.run("/heartbeat resume");
		await harness.run("/heartbeat off");

		expect(harness.server.requestsFor("sessions.heartbeat").map((frame) => frame.params)).toEqual([
			{ sessionKey: "tui-session", action: "status" },
			{ sessionKey: "tui-session", action: "pause" },
			{ sessionKey: "tui-session", action: "resume" },
			{ sessionKey: "tui-session", action: "clear" },
		]);
	});

	test("rejects intervals below the durable runtime minimum locally", async () => {
		await harness.run("/heartbeat every 59s check too often");

		expect(harness.server.requestsFor("sessions.heartbeat")).toHaveLength(0);
		expect(harness.host.last?.level).toBe("error");
		expect(harness.host.text).toContain("minimum is 60s");
	});
});

describe("diagnostics", () => {
	test("/status renders a card from status + health", async () => {
		harness.server.respondWith("status", {
			server: { version: "2026.08.0", uptime_ms: 3_600_000, memory_mb: 128.5 },
			connections: { active: 2, operators: 1 },
			runs: { active: 1, queued: 0, completed_today: 7 },
			channels: { configured: ["telegram"], connected: ["telegram"] },
			skills: { installed: 10, enabled: 8 },
		});
		harness.server.respondWith("health", { ok: true, checks: { router: { status: "ok" } } });

		await harness.run("/status");
		const text = harness.host.text;
		expect(text).toContain("2026.08.0");
		expect(text).toContain("uptime: 1h 0m");
		expect(text).toContain("telegram");
		expect(text).toContain("router: ok");
		expect(text).toContain("tui-session");
	});

	test("/usage renders totals and caches them for the gauge", async () => {
		harness.server.respondWith("usage.status", {
			period: "today",
			runs: 12,
			tokens: { input: 48_000, output: 12_000 },
			cost: 1.234,
			summary: { status: "within_limits", totalTokens: 60_000 },
			providers: [{ provider: "anthropic", requests: 12, cost: 1.234 }],
		});
		await harness.run("/usage");
		expect(harness.host.text).toContain("48k in");
		expect(harness.host.text).toContain("$1.23");
		expect(harness.store.usage).toBeDefined();
		expect(harness.host.statusRefreshes).toBeGreaterThan(0);
	});

	test("/cost translates a range word into startDate/endDate", async () => {
		harness.server.respondWith("usage.cost", {
			startDate: "2026-08-10",
			endDate: "2026-08-17",
			totalCost: 4.5,
			breakdown: { anthropic: 4.5 },
		});
		await harness.run("/cost week");
		const params = harness.server.requestsFor("usage.cost")[0].params as Record<string, unknown>;
		expect(typeof params.startDate).toBe("string");
		expect(typeof params.endDate).toBe("string");
		expect(params.startDate as string).toMatch(/^\d{4}-\d{2}-\d{2}$/);
		expect(params.range).toBeUndefined();
		expect(harness.host.text).toContain("$4.50");
		expect(harness.host.text).toContain("anthropic");
	});

	test("/cost rejects an unknown range word locally", async () => {
		await harness.run("/cost fortnight");
		expect(harness.server.requestsFor("usage.cost")).toHaveLength(0);
		expect(harness.host.text).toContain("unrecognized range");
	});

	test("/logs tails with a limit and a level", async () => {
		harness.server.respondWith("logs.tail", {
			logs: [{ level: "error", message: "boom", timestampMs: 1_700_000_000_000 }],
			total: 1,
		});
		await harness.run("/logs 5 error");
		expect(harness.server.requestsFor("logs.tail")[0].params).toMatchObject({
			limit: 5,
			level: "error",
		});
		expect(harness.host.text).toContain("boom");
	});
});

describe("runs and goals", () => {
	test("/abort says so when nothing is running", async () => {
		await harness.run("/abort");
		expect(harness.host.text).toContain("nothing is running");
		expect(harness.server.requestsFor("chat.abort")).toHaveLength(0);
	});

	test("/abort stops the active run", async () => {
		harness.server.respondWith("chat.abort", { aborted: true, runId: "run-9" });
		harness.store.focused.activeRunId = "run-9";
		await harness.run("/abort");
		expect(harness.server.requestsFor("chat.abort")[0].params).toEqual({
			runId: "run-9",
			sessionKey: "tui-session",
		});
	});

	test("/stop is the Hermes alias for /abort", async () => {
		harness.server.respondWith("chat.abort", { aborted: true, runId: "run-stop" });
		harness.store.focused.activeRunId = "run-stop";
		await harness.run("/stop");
		expect(harness.server.requestsFor("chat.abort")[0].params).toEqual({
			runId: "run-stop",
			sessionKey: "tui-session",
		});
	});

	test("/runs merges the active and recent lists", async () => {
		harness.server.respondWith("runs.active.list", {
			runs: [{ runId: "run-1", status: "running", engine: "codex" }],
		});
		harness.server.respondWith("runs.recent.list", {
			runs: [{ runId: "run-0", status: "ok", durationMs: 2500 }],
		});
		await harness.run("/runs");
		expect(harness.host.text).toContain("run-1");
		expect(harness.host.text).toContain("2.5s");
	});

	test("/goal set sends the whole objective", async () => {
		harness.server.respondWith("goal.set", { id: "goal-1", status: "active" });
		await harness.run("/goal set ship the release today");
		expect(harness.server.requestsFor("goal.set")[0].params).toEqual({
			sessionKey: "tui-session",
			objective: "ship the release today",
		});
	});

	test("/goal status reports what the daemon knows", async () => {
		harness.server.respondWith("goal.status", {
			goals: [{ status: "active", objectiveBytes: 42, continuationCount: 3 }],
		});
		await harness.run("/goal status");
		expect(harness.host.text).toContain("active");
		expect(harness.host.text).toContain("3 continuation(s)");
	});

	test("/queue reports an empty queue with the current mode", async () => {
		await harness.run("/queue");
		expect(harness.host.text).toContain("queue is empty");
		expect(harness.host.text).toContain("queue");
	});

	test("/queue and /q submit prompt text through forced queue mode", async () => {
		await harness.run("/queue follow this up");
		await harness.run("/q another thought");
		expect(harness.host.deliveries).toEqual([
			{ text: "follow this up", mode: "queue" },
			{ text: "another thought", mode: "queue" },
		]);
	});

	test("/steer submits guidance through forced steer mode", async () => {
		await harness.run("/steer focus on the failing test");
		expect(harness.host.deliveries).toEqual([{ text: "focus on the failing test", mode: "steer" }]);
	});

	test("/agents renders the Lemon agent directory", async () => {
		harness.server.respondWith("agents.list", {
			agents: [
				{
					agentId: "researcher",
					name: "Researcher",
					description: "Finds primary sources",
					sessionCount: 3,
					activeSessionCount: 1,
				},
			],
		});
		await harness.run("/agents");
		expect(harness.host.text).toContain("Researcher (researcher)");
		expect(harness.host.text).toContain("1 active");
	});

	test("/tasks combines active and recent task views", async () => {
		harness.server.respondWith("tasks.active.list", {
			tasks: [{ taskId: "task-live", status: "active", agentId: "builder" }],
		});
		harness.server.respondWith("tasks.recent.list", {
			tasks: [{ taskId: "task-done", status: "completed", durationMs: 1200 }],
		});
		await harness.run("/tasks 5");
		expect(harness.server.requestsFor("tasks.active.list")[0].params).toEqual({ limit: 5 });
		expect(harness.host.text).toContain("task-live");
		expect(harness.host.text).toContain("task-done");
	});

	test("/bg and /btw inherit the durable session key and current TUI context", async () => {
		harness.store.focused.model = "gpt-5";
		harness.store.focused.thinkingLevel = "high";
		const id = "019d-background-run-full-identifier-1234567890";
		harness.server.respondWith("background.start", { id, status: "queued" });
		harness.server.respondWith("session.btw", { answer: "The quick answer." });

		await harness.run("/bg investigate the flaky test");
		await harness.run("/btw what changed?");

		expect(harness.server.requestsFor("background.start")[0].params).toEqual({
			prompt: "investigate the flaky test",
			sessionKey: "tui-session",
			cwd: "/workspace/project",
			model: "gpt-5",
			thinkingLevel: "high",
		});
		expect(harness.server.requestsFor("background.start")[0].params).not.toHaveProperty(
			"sessionId",
		);
		expect(harness.server.requestsFor("session.btw")[0].params).toEqual({
			sessionKey: "tui-session",
			question: "what changed?",
		});
		expect(harness.host.text).toContain(id);
		expect(harness.host.text).toContain("The quick answer.");
	});

	test("/bg exposes list, status, result, and cancel lifecycle operations with full ids", async () => {
		const id = "019d-background-run-full-identifier-abcdefghijklmnopqrstuvwxyz";
		harness.server.respondWith("background.list", {
			runs: [
				{
					id,
					status: "running",
					parent_session_key: "tui-session",
					result_available: false,
				},
			],
			total: 1,
		});
		harness.server.respondWith("background.status", {
			id,
			status: "completed",
			session_id: "bg_session_1",
			parent_session_key: "tui-session",
			result_available: true,
		});
		harness.server.respondWith("background.result", {
			id,
			ready: true,
			answer: "All checks passed.",
		});
		harness.server.respondWith("background.cancel", { id, cancelled: true });

		await harness.run("/bg list running");
		await harness.run(`/bg status ${id}`);
		await harness.run(`/bg result ${id}`);
		await harness.run(`/bg cancel ${id}`);

		expect(harness.server.requestsFor("background.list")[0].params).toEqual({
			status: "running",
		});
		expect(harness.server.requestsFor("background.status")[0].params).toEqual({ id });
		expect(harness.server.requestsFor("background.result")[0].params).toEqual({ id });
		expect(harness.server.requestsFor("background.cancel")[0].params).toEqual({ id });
		expect(harness.host.text).toContain(id);
		expect(harness.host.text).toContain("All checks passed.");
		expect(harness.host.text).toContain("cancelled");
	});
});

describe("approvals", () => {
	beforeEach(() => {
		harness.server.respondWith("exec.approval.resolve", { resolved: true });
		harness.server.respondWith("exec.approvals.get", {
			policy: {},
			approvals: [],
			pending: [
				{ approvalId: "ap-1", tool: "bash", sessionKey: "tui-session", rationale: "rm -rf /tmp/x" },
				{ approvalId: "ap-2", tool: "write", sessionKey: "tui-session" },
			],
		});
	});

	test("/approvals numbers the pending list", async () => {
		await harness.run("/approvals");
		expect(harness.host.text).toContain("1. bash");
		expect(harness.host.text).toContain("2. write");
		expect(harness.host.text).toContain("rm -rf /tmp/x");
	});

	test("/approve resolves the nth with the daemon's decision string", async () => {
		await harness.run("/approve 2 session");
		expect(harness.server.requestsFor("exec.approval.resolve")[0].params).toEqual({
			approvalId: "ap-2",
			decision: "approve_session",
		});
	});

	test("/approve defaults to the first and to once", async () => {
		await harness.run("/approve");
		expect(harness.server.requestsFor("exec.approval.resolve")[0].params).toEqual({
			approvalId: "ap-1",
			decision: "approve_once",
		});
	});

	test("/deny denies", async () => {
		await harness.run("/deny 1");
		expect(harness.server.requestsFor("exec.approval.resolve")[0].params).toEqual({
			approvalId: "ap-1",
			decision: "deny",
		});
	});

	test("an out-of-range index is refused before sending", async () => {
		await harness.run("/approve 9");
		expect(harness.server.requestsFor("exec.approval.resolve")).toHaveLength(0);
		expect(harness.host.last?.level).toBe("error");
	});
});

describe("sessions and history", () => {
	test("/resume replays stored history into the transcript", async () => {
		harness.server.respondWith("chat.history", {
			sessionKey: "tui-session",
			messages: [
				{ id: "m1", role: "user", content: "hello", timestampMs: 1 },
				{ id: "m2", role: "assistant", content: "hi there", timestampMs: 2 },
			],
		});
		await harness.run("/resume");
		expect(harness.server.requestsFor("chat.history")[0].params).toMatchObject({
			sessionKey: "tui-session",
			includeFullText: true,
		});
		expect(harness.host.replays[0]).toHaveLength(2);
	});

	test("/history summarizes without replaying", async () => {
		harness.server.respondWith("chat.history", {
			sessionKey: "tui-session",
			messages: [{ id: "m1", role: "user", content: "a long\nmulti line prompt", timestampMs: 1 }],
		});
		await harness.run("/history 5");
		expect(harness.server.requestsFor("chat.history")[0].params).toMatchObject({ limit: 5 });
		expect(harness.host.replays).toHaveLength(0);
		expect(harness.host.text).toContain("a long multi line prompt");
	});

	test("/sessions merges the daemon's lists into a picker", async () => {
		harness.server.respondWith("sessions.active.list", {
			sessions: [{ sessionKey: "tui-session", agentId: "main", runCount: 3 }],
		});
		harness.server.respondWith("sessions.list", {
			sessions: [{ sessionKey: "cold-one", updatedAtMs: 1_700_000_000_000 }],
		});
		await harness.run("/sessions");
		const picker = harness.host.pickers[0];
		expect(picker.items.map((item) => item.value).sort()).toEqual(["cold-one", "tui-session"]);
		expect(picker.items.find((item) => item.value === "tui-session")?.description).toContain(
			"current",
		);
	});

	test("/session reset clears the daemon's copy", async () => {
		harness.server.respondWith("sessions.reset", { ok: true });
		await harness.run("/session reset");
		expect(harness.server.requestsFor("sessions.reset")[0].params).toEqual({
			sessionKey: "tui-session",
		});
	});

	test("/reset is the top-level Hermes alias", async () => {
		harness.server.respondWith("sessions.reset", { ok: true });
		await harness.run("/reset");
		expect(harness.server.requestsFor("sessions.reset")[0].params).toEqual({
			sessionKey: "tui-session",
		});
		expect(harness.host.text).toContain("reset tui-session");
	});

	test("/compress compacts the current session", async () => {
		harness.server.respondWith("sessions.compact", {
			success: true,
			tokensBefore: 12000,
			tokensAfter: 4000,
		});
		await harness.run("/compress");
		expect(harness.server.requestsFor("sessions.compact")[0].params).toEqual({
			sessionKey: "tui-session",
		});
		expect(harness.host.text).toContain("12000 → 4000 tokens");
	});

	test("/session delete asks before it deletes", async () => {
		harness.server.respondWith("sessions.delete", { ok: true });
		await harness.run("/session delete");
		expect(harness.server.requestsFor("sessions.delete")).toHaveLength(0);
		expect(harness.host.last?.level).toBe("warning");
		await harness.run("/session delete tui-session");
		expect(harness.server.requestsFor("sessions.delete")[0].params).toEqual({
			sessionKey: "tui-session",
		});
	});

	test("/session info reports native runtime provenance without selecting it", async () => {
		harness.store.focused.model = "gpt-4o";
		harness.store.focused.engine = "lemon";
		await harness.run("/session info");
		expect(harness.host.text).toContain("gpt-4o");
		expect(harness.host.text).toContain("native runtime: lemon");
		expect(harness.host.text).not.toContain("engine:");
		expect(harness.server.requestsFor("session.detail")).toHaveLength(0);
	});
});

describe("client-local commands", () => {
	test("/mode sets the submission mode", async () => {
		await harness.run("/mode steer");
		expect(harness.store.submissionMode).toBe("steer");
		await harness.run("/mode nope");
		expect(harness.store.submissionMode).toBe("steer");
		expect(harness.host.last?.level).toBe("error");
	});

	test("/clear clears the transcript", async () => {
		await harness.run("/clear");
		expect(harness.host.cleared).toBe(1);
	});

	test("/quit exits", async () => {
		await harness.run("/quit");
		expect(harness.host.exits).toEqual([0]);
	});

	test("/q queues instead of quitting", async () => {
		await harness.run("/q keep going");
		expect(harness.host.exits).toEqual([]);
		expect(harness.host.deliveries).toEqual([{ text: "keep going", mode: "queue" }]);
	});

	test("/commands prefers the server catalog", async () => {
		harness.server.respondWith("commands.catalog", {
			commands: [
				{
					name: "queue",
					arguments: "<prompt>",
					description: "queue work",
					aliases: ["/q"],
				},
			],
		});
		await harness.run("/commands");
		expect(harness.host.text).toContain("daemon catalog");
		expect(harness.host.text).toContain("/queue <prompt>");
		expect(harness.host.text).toContain("aliases: /q");
	});

	test("/reconnect asks the client to redial", async () => {
		await harness.run("/reconnect");
		expect(harness.host.reconnects).toBe(1);
	});

	test("/debug shows the frame log", async () => {
		harness.host.frames = ["12:00:00.000 -> req status", "12:00:00.010 <- res status ok"];
		await harness.run("/debug");
		expect(harness.host.text).toContain("<- res status ok");
		expect(harness.host.text).toContain(harness.client.url);
	});

	test("/theme lists what it can install", async () => {
		await harness.run("/theme");
		expect(harness.host.text).toContain("lemon-dark");
		await harness.run("/theme neon");
		expect(harness.host.last?.level).toBe("error");
	});

	test("/editor delegates to the host's handoff", async () => {
		await harness.run("/editor");
		expect(harness.host.text).toContain("external editor opened");
	});
});
