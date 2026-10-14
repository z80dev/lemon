import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { AppShell } from "../src/app.ts";
import { FakeControlPlane } from "../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../src/protocol/client.ts";
import { ControlPlaneMethods } from "../src/protocol/methods.ts";
import type { SessionSummary } from "../src/protocol/types.ts";
import { cwdSessionTag } from "../src/session-key.ts";
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

describe("selectContinueSession", () => {
	const here = (id: string) => `agent:default:tui:local:dm:${cwdSessionTag(CWD)}-${id}`;
	const there = (id: string) => `agent:default:tui:local:dm:${cwdSessionTag(OTHER)}-${id}`;
	const legacy = "agent:default:tui:local:dm:11111111-1111-1111-1111-111111111111";

	test("picks this directory's newest session over a newer one elsewhere", () => {
		const rows = [row(there("a"), 900), row(here("old"), 100), row(here("new"), 500)];
		expect(selectContinueSession(rows, { cwd: CWD })).toBe(here("new"));
	});

	test("never continues another directory's or an untagged session", () => {
		const rows = [row(legacy, 300), row(there("a"), 700), row(there("b"), 200)];
		expect(selectContinueSession(rows, { cwd: CWD })).toBeUndefined();
	});

	test("ignores archived, non-TUI and excluded sessions", () => {
		const rows = [
			row(here("archived"), 900, { archived: true }),
			row("agent:default:cli-abc-xyz", 800),
			row("agent:default:main", 700),
			row(here("self"), 600),
			row(here("older"), 100),
		];
		expect(selectContinueSession(rows, { cwd: CWD, exclude: here("self") })).toBe(here("older"));
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

	test("--resume KEY attaches only on an exact key match", async () => {
		server.respondWith("sessions.list", { sessions: [row("k-1", 1), row("k-10", 2)], total: 2 });
		const resolution = await resolveStartup({ mode: "resume", key: "k-1" }, deps());
		expect(resolution).toEqual({ sessionKey: "k-1" });
	});

	test("--resume KEY falls back to a fresh session with a warning when it does not exist", async () => {
		server.respondWith("sessions.list", { sessions: [row("k-10", 2)], total: 1 });
		const resolution = await resolveStartup({ mode: "resume", key: "k-1" }, deps());
		expect(resolution.sessionKey).toBeUndefined();
		expect(resolution.notice?.level).toBe("warning");
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
		expect(server.requestsFor("sessions.list")).toHaveLength(2);
	});

	test("--continue starts fresh when nothing qualifies or the lookup fails", async () => {
		server.respondWith("sessions.list", { sessions: [row("agent:default:cli-a-b", 5)], total: 1 });
		expect((await resolveStartup({ mode: "continue" }, deps())).sessionKey).toBeUndefined();

		server.failWith("sessions.list", "UNAVAILABLE", "down");
		const failed = await resolveStartup({ mode: "continue" }, deps());
		expect(failed.sessionKey).toBeUndefined();
		expect(failed.notice?.level).toBe("error");
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

	test("--continue focuses the saved session and loads its history", async () => {
		const { app, server, saved } = await boot({ mode: "continue" });
		await waitFor(() => renderPlain(app.chatContainer.render(80)).includes("welcome back"));
		expect(app.sessionKey).toBe(saved);
		expect(server.requestsFor("chat.history").at(-1)?.params).toMatchObject({ sessionKey: saved });
		// The throwaway key minted at construction never becomes a session.
		expect([...app.store.sessions.keys()]).toEqual([saved]);
	});

	test("bare --resume opens the session switcher once loaded", async () => {
		const { app } = await boot({ mode: "resume" });
		await waitFor(() => app.selectors.isOpen);
		expect(app.selectors.isOpen).toBe(true);
	});
});
