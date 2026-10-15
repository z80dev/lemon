/**
 * Every command that reaches the daemon, against the fake control plane:
 * the right method, with the right params, and a readable notice back.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { reportedContextFixture } from "../../src/dev/fixtures/context-fixtures.ts";
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
		expect(frame.params).toEqual({ sessionKey: "tui-session", model: "anthropic:claude-sonnet-4" });
		expect(harness.store.focused.model).toBe("anthropic:claude-sonnet-4");
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

describe("heartbeat (cron-backed)", () => {
	const CRON_METHODS = [
		"cron.list",
		"cron.add",
		"cron.update",
		"cron.pause",
		"cron.resume",
		"cron.remove",
	];
	const heartbeatJob = {
		id: "hb-1",
		name: "heartbeat-default",
		schedule: "*/30 * * * *",
		timezone: "local",
		enabled: true,
		agentId: "default",
		sessionKey: "agent:default:main",
		prompt: "check CI and open reviews",
		nextRunAtMs: Date.UTC(2026, 8, 27, 12, 30),
		meta: { heartbeat: true, agent_id: "default" },
	};
	// A same-agent cron job that is not the heartbeat must never be touched.
	const otherJob = { id: "job-9", agentId: "default", enabled: true, meta: { source: "remind" } };

	const cronRequests = () => CRON_METHODS.flatMap((method) => harness.server.requestsFor(method));

	test("/heartbeat every creates the agent's heartbeat job when none exists", async () => {
		harness.server.respondWith("cron.list", { jobs: [otherJob] });
		harness.server.respondWith("cron.add", { id: "hb-new", nextRunAtMs: heartbeatJob.nextRunAtMs });

		await harness.run("/heartbeat every 30m check CI and open reviews");

		expect(harness.server.requestsFor("cron.list")[0].params).toEqual({
			agentId: "default",
			includeTargetText: false,
		});
		expect(harness.server.requestsFor("cron.add")[0].params).toEqual({
			name: "heartbeat-default",
			schedule: "every 30m",
			agentId: "default",
			sessionKey: "agent:default:main",
			prompt: "check CI and open reviews",
			timezone: "local",
			meta: { heartbeat: true, agent_id: "default" },
		});
		expect(harness.server.requestsFor("cron.update")).toHaveLength(0);
		expect(harness.host.text).toContain("heartbeat set · every 30m");
		expect(harness.host.text).toContain("next run 2026-09-27 12:30:00");
		expect(harness.host.text).toContain("paired Telegram chat");
		expect(harness.host.text).toContain("HEARTBEAT_OK is suppressed");
	});

	test("/hb every replaces the existing heartbeat job in place and re-enables it", async () => {
		harness.server.respondWith("cron.list", {
			jobs: [otherJob, { ...heartbeatJob, enabled: false }],
		});
		harness.server.respondWith("cron.update", { id: "hb-1", updated: true });

		await harness.run("/hb every 2h summarize the inbox");

		expect(harness.server.requestsFor("cron.update")[0].params).toEqual({
			id: "hb-1",
			schedule: "every 2h",
			prompt: "summarize the inbox",
			timezone: "local",
			enabled: true,
		});
		expect(harness.server.requestsFor("cron.add")).toHaveLength(0);
		expect(harness.host.text).toContain("heartbeat updated · every 2h");
	});

	test("maps 1d to the daily schedule and 60m to an hourly one", async () => {
		harness.server.respondWith("cron.list", { jobs: [] });
		harness.server.respondWith("cron.add", { id: "hb-new" });

		await harness.run("/heartbeat every 1d morning brief");
		await harness.run("/heartbeat 60m quick check");

		expect(harness.server.requestsFor("cron.add").map((frame) => frame.params)).toMatchObject([
			{ schedule: "daily" },
			{ schedule: "every 1h" },
		]);
	});

	test("a profile main session targets its own agent", async () => {
		harness.stop();
		harness = await createHarness({ sessionKey: "agent:ops:main", cwd: "/workspace/project" });
		harness.server.respondWith("cron.list", { jobs: [] });
		harness.server.respondWith("cron.add", { id: "hb-ops" });

		await harness.run("/heartbeat every 15m watch the deploy");

		expect(harness.server.requestsFor("cron.add")[0].params).toMatchObject({
			name: "heartbeat-ops",
			agentId: "ops",
			sessionKey: "agent:ops:main",
			meta: { heartbeat: true, agent_id: "ops" },
		});
	});

	test("rejects intervals that are not cron-exact before any cron call", async () => {
		for (const line of [
			"/heartbeat every 45m too odd",
			"/heartbeat every 90m too odd",
			"/heartbeat every 5h too odd",
			"/heartbeat every 2d too long",
		]) {
			await harness.run(line);
			expect(harness.host.last?.level).toBe("error");
			expect(harness.host.last?.text).toContain("not cron-exact");
		}

		await harness.run("/heartbeat every 30s too often");
		expect(harness.host.last?.level).toBe("error");
		expect(harness.host.last?.text).toContain("minimum is 1m");

		expect(cronRequests()).toHaveLength(0);
	});

	test("/heartbeat status shows schedule, state, next run and prompt", async () => {
		harness.server.respondWith("cron.list", { jobs: [otherJob, heartbeatJob] });

		await harness.run("/heartbeat status");

		expect(harness.server.requestsFor("cron.list")[0].params).toEqual({
			agentId: "default",
			includeTargetText: true,
		});
		expect(harness.host.text).toContain("heartbeat · enabled · */30 * * * * (local)");
		expect(harness.host.text).toContain("next run: 2026-09-27 12:30:00");
		expect(harness.host.text).toContain("check CI and open reviews");
	});

	test("/hb with no heartbeat configured says so", async () => {
		harness.server.respondWith("cron.list", { jobs: [otherJob] });

		await harness.run("/hb");

		expect(harness.host.text).toContain("no heartbeat is configured for agent default");
	});

	test("pause, resume and clear act on the heartbeat job only", async () => {
		harness.server.respondWith("cron.list", { jobs: [otherJob, heartbeatJob] });
		harness.server.respondWith("cron.pause", { id: "hb-1", paused: true });
		harness.server.respondWith("cron.resume", { id: "hb-1", resumed: true });
		harness.server.respondWith("cron.remove", { id: "hb-1", removed: true });

		await harness.run("/heartbeat pause");
		await harness.run("/heartbeat resume");
		await harness.run("/heartbeat off");

		expect(harness.server.requestsFor("cron.pause").map((frame) => frame.params)).toEqual([
			{ id: "hb-1" },
		]);
		expect(harness.server.requestsFor("cron.resume").map((frame) => frame.params)).toEqual([
			{ id: "hb-1" },
		]);
		expect(harness.server.requestsFor("cron.remove").map((frame) => frame.params)).toEqual([
			{ id: "hb-1" },
		]);
		expect(harness.host.text).toContain("heartbeat paused");
		expect(harness.host.text).toContain("heartbeat resumed");
		expect(harness.host.text).toContain("heartbeat cleared");
	});

	test("lifecycle actions without a heartbeat warn and mutate nothing", async () => {
		harness.server.respondWith("cron.list", { jobs: [otherJob] });

		await harness.run("/heartbeat clear");

		expect(harness.host.last?.level).toBe("warning");
		expect(harness.server.requestsFor("cron.remove")).toHaveLength(0);
	});

	test("the config-owned daily brief is never treated as the /heartbeat job", async () => {
		const dailyBrief = {
			...heartbeatJob,
			id: "cron_daily_brief",
			name: "Daily brief",
			meta: { heartbeat: true, daily_brief: true, agent_id: "default" },
		};
		harness.server.respondWith("cron.list", { jobs: [dailyBrief] });

		await harness.run("/heartbeat clear");

		expect(harness.host.last?.level).toBe("warning");
		expect(harness.server.requestsFor("cron.remove")).toHaveLength(0);
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
		expect(text).toContain("profile: none (ordinary chat)");
		expect(text).toContain("model: not selected — /model to choose");
		expect(text).toContain("tui-session");
	});

	test("/status includes the focused profile and model", async () => {
		harness.store.setFocused("agent:research:main");
		harness.store.focused.setModel({ model: "openai:gpt-5" }, "local");
		harness.server.respondWith("status", { server: { version: "test" } });
		await harness.run("/status");
		expect(harness.host.text).toContain("profile: research");
		expect(harness.host.text).toContain("model: openai:gpt-5");
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
		expect(harness.store.usage?.summary).toEqual({ status: "within_limits", totalTokens: 60_000 });
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
		expect(params.startDate as string).toMatch(/^\d{4}-\d{2}-\d{2}$/);
		expect(params.endDate as string).toMatch(/^\d{4}-\d{2}-\d{2}$/);
		expect(params.range).toBeUndefined();
		expect(harness.host.text).toContain("$4.50");
		expect(harness.host.text).toContain("anthropic");
	});

	test("/cost rejects an unknown range word locally", async () => {
		await harness.run("/cost fortnight");
		expect(harness.server.requestsFor("usage.cost")).toHaveLength(0);
		expect(harness.host.text).toContain("unrecognized range");
	});

	for (const [by, section, identity] of [
		["day", "dailyUsage", { date: "2026-10-01" }],
		["provider", "providers", { provider: "openai" }],
		["model", "models", { provider: "openai", model: "gpt-test" }],
		["session", "sessions", { sessionKey: "agent:test:one" }],
	] as const) {
		test(`/cost 7d --by ${by} renders the selected breakdown and omissions`, async () => {
			harness.server.respondWith("usage.cost", {
				incomplete: true,
				sessionsOmitted: 9,
				totalCost: 0,
				[section]: [{ ...identity, cost: 0, requests: 2, inputTokens: 30, outputTokens: 4 }],
			});
			await harness.run(`/cost 7d --by ${by}`);
			expect(harness.server.requestsFor("usage.cost")[0].params).toMatchObject({ groupBy: by });
			expect(harness.host.text).toContain(Object.values(identity).at(-1)!);
			expect(harness.host.text).toContain("30 in");
			expect(harness.host.text).toContain("4 out");
			expect(harness.host.text).toContain("incomplete: true");
			expect(harness.host.text).toContain("sessions omitted: 9");
			expect(harness.host.text).toContain("unknown pricing");
		});
	}

	test("/cost refuses invalid grouping and extra arguments without RPC", async () => {
		for (const args of ["--by", "--by invalid", "7d extra", "--wat"]) {
			await harness.run(`/cost ${args}`);
		}
		expect(harness.server.requestsFor("usage.cost")).toHaveLength(0);
	});

	test("/cost complete reports do not label known zero prices as unknown", async () => {
		harness.server.respondWith("usage.cost", {
			incomplete: false,
			sessionsOmitted: 0,
			totalCost: 0,
			dailyUsage: [],
		});
		await harness.run("/cost --by day");
		expect(harness.host.text).toContain("incomplete: false");
		expect(harness.host.text).toContain("none");
		expect(harness.host.text).not.toContain("unknown pricing");
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

	test("/redirect submits replacement guidance through forced redirect mode", async () => {
		await harness.run("/redirect replace the pending direction");
		expect(harness.host.deliveries).toEqual([
			{ text: "replace the pending direction", mode: "redirect" },
		]);
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
			cwd: "/workspace/project",
		});
		expect(harness.host.text).toContain("12000 → 4000 tokens");
	});

	test("/compact preserves the full focus instructions and forwards cwd", async () => {
		harness.server.respondWith("sessions.compact", { success: true });
		await harness.run('/compact Keep  the "API contract"\n  and pending tasks');
		expect(harness.server.requestsFor("sessions.compact")[0].params).toEqual({
			sessionKey: "tui-session",
			cwd: "/workspace/project",
			focus: 'Keep  the "API contract"\n  and pending tasks',
		});
	});

	test("compaction refusal exposes neither server exception nor summary", async () => {
		harness.server.failWith("sessions.compact", "FORBIDDEN", "private exception /secret/path");
		await harness.run("/compact preserve tests");
		expect(harness.host.last?.level).toBe("error");
		expect(harness.host.text).not.toContain("private exception");
		expect(harness.host.text).not.toContain("/secret/path");
		harness.server.respondWith("sessions.compact", { success: false, summary: "private summary" });
		await harness.run("/compress");
		expect(harness.host.last?.level).toBe("error");
		expect(harness.host.text).not.toContain("private summary");
	});

	test("typed compaction retains supported supplied-summary and force inputs", async () => {
		harness.server.respondWith("sessions.compact", { success: true });
		const params = {
			sessionKey: "tui-session",
			cwd: "/workspace/project",
			focus: "preserve API decisions",
			summary: "Caller-supplied summary",
			force: false,
		};
		await harness.methods.sessionsCompact(params);
		expect(harness.server.requestsFor("sessions.compact")[0].params).toEqual(params);
	});

	test("/session delete previews and requires the exact key before it deletes", async () => {
		harness.server.respondWith("sessions.get", {
			session: {
				sessionKey: "tui-session",
				runCount: 1,
				pinned: false,
				archived: false,
			},
		});
		harness.server.respondWith("sessions.delete", {
			deleted: true,
			sessionKey: "tui-session",
			summary: { existed: true, verified: true },
		});
		await harness.run("/session delete");
		expect(harness.server.requestsFor("sessions.delete")).toHaveLength(0);
		expect(harness.host.last?.level).toBe("warning");
		await harness.run("/session delete tui-session --confirm tui-session");
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

	test("/session info appends cumulative usage and survives a failing or usage-less sessions.context", async () => {
		harness.server.serveSessionContext({
			"tui-session": reportedContextFixture("tui-session"),
		});
		await harness.run("/session info");
		expect(harness.host.text).toContain("cost $0.42");

		harness.host.notices.length = 0;
		harness.store.focused.engine = "lemon";
		harness.server.failWith("sessions.context", "INTERNAL_ERROR", "/secret/path exploded");
		await harness.run("/session info");
		expect(harness.host.text).toContain("native runtime: lemon");
		expect(harness.host.text).not.toContain("/secret");

		harness.host.notices.length = 0;
		const { usage: _usage, ...withoutUsage } = reportedContextFixture("tui-session");
		harness.server.respondWith("sessions.context", withoutUsage);
		await harness.run("/session info");
		expect(harness.host.text).not.toContain("cost $");
	});
});

describe("client-local commands", () => {
	test("/mode sets the submission mode", async () => {
		await harness.run("/mode redirect");
		expect(harness.store.submissionMode).toBe("redirect");
		await harness.run("/mode nope");
		expect(harness.store.submissionMode).toBe("redirect");
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
		expect(harness.host.text).toContain(`connected to ${harness.client.url}`);
	});

	test("/reconnect reports a failed attempt", async () => {
		harness.host.reconnect = async () => {
			throw new Error("not reachable — start Lemon");
		};
		await harness.run("/reconnect");
		expect(harness.host.last).toEqual({
			text: "reconnect failed: not reachable — start Lemon",
			level: "error",
		});
	});

	test("/faq does not suggest the unrelated /q alias", async () => {
		await harness.run("/faq");
		expect(harness.host.last?.text).toBe("unknown command /faq");
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
