import { afterEach, expect, test } from "bun:test";
import type { CommandHost } from "../../src/commands/index.ts";
import { reportedContextFixture } from "../../src/dev/fixtures/context-fixtures.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

let harness: Harness | undefined;
afterEach(() => {
	harness?.stop();
	harness = undefined;
});

async function boot(methods = ["sessions.context"]): Promise<Harness> {
	harness = await createHarness({ methods, sessionKey: "tui-ctx", cwd: "/work/project" });
	return harness;
}

test("/context fetches the focused session with the TUI cwd and opens the panel", async () => {
	const h = await boot();
	h.server.serveSessionContext({ "tui-ctx": reportedContextFixture("tui-ctx") });
	await h.run("/context");
	expect(h.server.requestsFor("sessions.context")[0]?.params).toEqual({
		sessionKey: "tui-ctx",
		cwd: "/work/project",
	});
	expect(h.host.contextPanels).toHaveLength(1);
	expect(h.host.contextPanels[0]?.usedTokens).toBe(45_210);
	expect(h.host.notices).toHaveLength(1);
	expect(h.host.last).toEqual({
		text: "tokens 120k in / 14.5k out / 47.9k cache (40k read, 7.9k write) · cost $0.42 (estimate)",
		level: "info",
	});
});

test("a successful measurement feeds the status-bar gauge", async () => {
	const h = await boot();
	h.server.serveSessionContext({ "tui-ctx": reportedContextFixture("tui-ctx") });
	const refreshes = h.host.statusRefreshes;
	await h.run("/ctx");
	expect(h.store.focused.contextTokens).toBe(45_210);
	expect(h.store.focused.contextMeasurement).toEqual({ tokens: 45_210, window: 200_000 });
	expect(h.host.statusRefreshes).toBeGreaterThan(refreshes);
});

test("a run that completes while the request is in flight keeps its newer usage", async () => {
	const h = await boot();
	h.server.onMethod("sessions.context", () => {
		h.store.focused.applyUsage({ contextTokens: 50_000 });
		return reportedContextFixture("tui-ctx");
	});
	await h.run("/context");
	expect(h.store.focused.contextTokens).toBe(50_000);
	expect(h.host.contextPanels).toHaveLength(1);
});

test("not_found explains that nothing has been recorded yet", async () => {
	const h = await boot();
	h.server.serveSessionContext({});
	await h.run("/context");
	expect(h.host.last).toEqual({
		text: "No context recorded yet — send a prompt first.",
		level: "info",
	});
	expect(h.host.contextPanels).toHaveLength(0);
	expect(h.store.focused.contextMeasurement).toBeUndefined();
});

test("unavailable and other server failures never echo raw server details", async () => {
	const h = await boot();
	h.server.failWith("sessions.context", "UNAVAILABLE", "/secret/path exploded", { path: "/x" });
	await h.run("/context");
	expect(h.host.last?.text).toContain("unavailable");
	h.server.failWith("sessions.context", "INTERNAL_ERROR", "/secret/path exploded");
	await h.run("/context");
	expect(h.host.last).toEqual({
		text: "Context usage request failed (INTERNAL_ERROR).",
		level: "error",
	});
	expect(h.host.text).not.toContain("/secret");
});

test("an unreadable receipt is reported without rendering a panel", async () => {
	const h = await boot();
	h.server.respondWith("sessions.context", { sessionKey: "tui-ctx" });
	await h.run("/context");
	expect(h.host.last?.level).toBe("error");
	h.server.respondWith("sessions.context", reportedContextFixture("someone-else"));
	await h.run("/context");
	expect(h.host.contextPanels).toHaveLength(0);
	expect(h.store.focused.contextMeasurement).toBeUndefined();
});

test("is disabled, without dialing, when the daemon does not advertise sessions.context", async () => {
	const h = await boot(["chat.send"]);
	await h.run("/context");
	expect(h.host.last?.level).toBe("warning");
	expect(h.host.text).toContain("sessions.context");
	expect(h.server.requestsFor("sessions.context")).toHaveLength(0);
});

test("is disabled in a host without a context panel", async () => {
	const h = await boot();
	(h.host as CommandHost).openContextPanel = undefined;
	await h.run("/context");
	expect(h.host.text).toContain("no context panel");
	expect(h.server.requestsFor("sessions.context")).toHaveLength(0);
});

test("offline is reported and nothing is queued", async () => {
	const h = await boot();
	h.server.stop();
	h.client.close();
	await h.run("/context");
	expect(h.host.last?.text).toContain("nothing was queued");
	expect(h.client.queued).toHaveLength(0);
});

test("rejects arguments", async () => {
	const h = await boot();
	await h.run("/context everything");
	expect(h.host.last?.level).toBe("warning");
	expect(h.server.requestsFor("sessions.context")).toHaveLength(0);
});
