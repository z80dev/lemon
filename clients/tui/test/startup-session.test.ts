import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { AppShell } from "../src/app.ts";
import { FakeControlPlane } from "../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../src/protocol/client.ts";
import { ControlPlaneMethods } from "../src/protocol/methods.ts";
import type { SessionSummary } from "../src/protocol/types.ts";
import { cwdSessionTag, newSessionKey } from "../src/session-key.ts";
import { resolveStartup, selectContinueSession } from "../src/startup-session.ts";
import { initTheme, resetTheme } from "../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal, renderPlain } from "./helpers/memory-terminal.ts";
import { waitFor } from "./helpers/wait.ts";

const CWD = "/work/project";
const OTHER = "/work/other";

function row(
	key: string,
	updatedAtMs: number,
	extra: Partial<SessionSummary> = {},
): SessionSummary {
	return { sessionKey: key, updatedAtMs, ...extra };
}

describe("newSessionKey", () => {
	test("tags keys with the directory, matching the CLI hash recipe", () => {
		const key = newSessionKey(CWD);
		expect(key).toMatch(/^agent:default:tui:local:dm:[0-9a-f]{16}-[0-9a-f-]{36}$/);
		expect(key).toContain(`:dm:${cwdSessionTag(CWD)}-`);
		expect(cwdSessionTag(CWD)).not.toBe(cwdSessionTag(OTHER));
	});
});

describe("selectContinueSession", () => {
	const here = (id: string) => `agent:default:tui:local:dm:${cwdSessionTag(CWD)}-${id}`;
	const there = (id: string) => `agent:default:tui:local:dm:${cwdSessionTag(OTHER)}-${id}`;
	const legacy = "agent:default:tui:local:dm:11111111-1111-1111-1111-111111111111";

	test("prefers this directory's newest session over a newer one elsewhere", () => {
		const rows = [row(there("a"), 900), row(here("old"), 100), row(here("new"), 500)];
		expect(selectContinueSession(rows, { cwd: CWD })).toEqual({ key: here("new"), scope: "cwd" });
	});

	test("falls back to the newest local TUI session when none belongs to this directory", () => {
		const rows = [row(legacy, 300), row(there("a"), 700), row(there("b"), 200)];
		expect(selectContinueSession(rows, { cwd: CWD })).toEqual({ key: there("a"), scope: "any" });
	});

	test("ignores archived, non-TUI and excluded sessions", () => {
		const rows = [
			row(here("archived"), 900, { archived: true }),
			row("agent:default:cli-abc-xyz", 800),
			row("agent:default:main", 700),
			row(here("self"), 600),
			row(legacy, 100),
		];
		expect(selectContinueSession(rows, { cwd: CWD, exclude: here("self") })).toEqual({
			key: legacy,
			scope: "any",
		});
	});

	test("rows without a timestamp rank oldest, and nothing yields undefined", () => {
		expect(selectContinueSession([], { cwd: CWD })).toBeUndefined();
		const rows = [{ sessionKey: here("untimed") }, row(here("timed"), 1)];
		expect(selectContinueSession(rows, { cwd: CWD })?.key).toBe(here("timed"));
	});
});

describe("resolveStartup", () => {
	let server: FakeControlPlane;
	let client: ControlPlaneClient;
	let methods: ControlPlaneMethods;

	beforeEach(async () => {
		server = await FakeControlPlane.start({ methods: ["sessions.list"] });
		client = new ControlPlaneClient({ url: server.url });
		await client.connect();
		methods = new ControlPlaneMethods(client);
	});
	afterEach(() => {
		client.close();
		server.stop();
	});

	const deps = () => ({ methods, cwd: CWD, currentKey: "fresh" });

	test("bare --resume opens the switcher without touching the daemon", async () => {
		expect(await resolveStartup({ mode: "resume" }, deps())).toEqual({ openSwitcher: true });
		expect(server.requestsFor("sessions.list")).toHaveLength(0);
	});

	test("--resume KEY attaches when the exact key exists", async () => {
		server.respondWith("sessions.list", { sessions: [row("k-1", 1), row("k-10", 2)], total: 2 });
		const resolution = await resolveStartup({ mode: "resume", key: "k-1" }, deps());
		expect(resolution).toEqual({ sessionKey: "k-1" });
		expect(server.requestsFor("sessions.list")[0].params).toMatchObject({ query: "k-1" });
	});

	test("--resume KEY falls back to a fresh session with a notice when it does not exist", async () => {
		server.respondWith("sessions.list", { sessions: [row("k-10", 2)], total: 1 });
		const resolution = await resolveStartup({ mode: "resume", key: "k-1" }, deps());
		expect(resolution.sessionKey).toBeUndefined();
		expect(resolution.notice?.level).toBe("warning");
		expect(resolution.notice?.text).toContain("k-1");
	});

	test("--resume KEY still attaches, with a warning, when the lookup fails", async () => {
		server.failWith("sessions.list", "UNAVAILABLE", "down");
		const resolution = await resolveStartup({ mode: "resume", key: "k-1" }, deps());
		expect(resolution.sessionKey).toBe("k-1");
		expect(resolution.notice?.level).toBe("warning");
	});

	test("--continue pages the whole list and picks this directory's newest session", async () => {
		const mine = `agent:default:tui:local:dm:${cwdSessionTag(CWD)}-b`;
		server.onMethod("sessions.list", (params: { offset?: number }) =>
			(params.offset ?? 0) === 0
				? { sessions: [row("agent:default:tui:local:dm:x", 900)], total: 2 }
				: { sessions: [row(mine, 10)], total: 2 },
		);
		const resolution = await resolveStartup({ mode: "continue" }, deps());
		expect(resolution.sessionKey).toBe(mine);
		expect(resolution.notice?.text).toContain("this directory");
		expect(server.requestsFor("sessions.list").map((r) => r.params)).toEqual([
			{ limit: 500, offset: 0, archived: false },
			{ limit: 500, offset: 1, archived: false },
		]);
	});

	test("--continue starts fresh with a notice when nothing qualifies", async () => {
		server.respondWith("sessions.list", { sessions: [row("agent:default:cli-a-b", 5)], total: 1 });
		const resolution = await resolveStartup({ mode: "continue" }, deps());
		expect(resolution.sessionKey).toBeUndefined();
		expect(resolution.notice?.text).toContain("no previous session");
	});

	test("--continue reports a failed lookup instead of throwing", async () => {
		server.failWith("sessions.list", "UNAVAILABLE", "down");
		const resolution = await resolveStartup({ mode: "continue" }, deps());
		expect(resolution.sessionKey).toBeUndefined();
		expect(resolution.notice?.level).toBe("error");
	});
});

describe("AppShell startup request", () => {
	const teardown: Array<() => void> = [];
	beforeEach(() => initTheme({ colorLevel: 3 }));
	afterEach(() => {
		while (teardown.length > 0) teardown.pop()?.();
		resetTheme();
		invalidateThemeAdapters();
	});

	async function boot(startup: ConstructorParameters<typeof AppShell>[0]["startup"]) {
		const server = await FakeControlPlane.start();
		teardown.push(() => server.stop());
		const saved = `agent:default:tui:local:dm:${cwdSessionTag("/repo")}-saved`;
		server.respondWith("sessions.list", { sessions: [row(saved, 10)], total: 1 });
		server.respondWith("sessions.active.list", { sessions: [] });
		server.respondWith("exec.approvals.get", { approvals: [] });
		server.onMethod("chat.history", (params: { sessionKey: string }) => ({
			messages:
				params.sessionKey === saved
					? [{ id: "a1", role: "assistant", content: "welcome back" }]
					: [],
		}));
		const terminal = new MemoryTerminal();
		const app = new AppShell({
			url: server.url,
			cwd: "/repo",
			startup,
			version: "test",
			terminal,
			client: new ControlPlaneClient({
				url: server.url,
				socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
			}),
		});
		teardown.push(() => app.stop());
		await app.start();
		return { app, server, saved };
	}

	test("--continue focuses the saved session, loads its history and says so", async () => {
		const { app, server, saved } = await boot({ mode: "continue" });
		await waitFor(() => renderPlain(app.chatContainer.render(80)).includes("welcome back"));
		expect(app.sessionKey).toBe(saved);
		expect(server.requestsFor("chat.history").at(-1)?.params).toMatchObject({ sessionKey: saved });
		expect(renderPlain(app.chatContainer.render(80))).toContain("continuing the latest session");
		// The throwaway key minted at construction never becomes a session.
		expect([...app.store.sessions.keys()]).toEqual([saved]);
	});

	test("--resume with an unknown key keeps a fresh session and warns", async () => {
		const { app } = await boot({ mode: "resume", key: "missing" });
		await waitFor(() => renderPlain(app.chatContainer.render(80)).includes("was not found"));
		expect(app.sessionKey).toMatch(/^agent:default:tui:local:dm:/);
		expect(app.sessionKey).not.toBe("missing");
	});

	test("bare --resume opens the session switcher once loaded", async () => {
		const { app } = await boot({ mode: "resume" });
		await waitFor(() => app.selectors.isOpen);
		expect(app.selectors.isOpen).toBe(true);
	});
});
