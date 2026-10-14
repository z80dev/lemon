import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { AppShell } from "../../src/app.ts";
import {
	DEFAULT_METHODS,
	errorResult,
	FakeControlPlane,
	type MethodContext,
	NO_RESPONSE,
} from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import { cwdSessionTag, newSessionKey } from "../../src/session-key.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal } from "../helpers/memory-terminal.ts";

const CWD = "/repo";
const PROMPT = "recover the first failed turn";
const teardown: Array<() => void> = [];

beforeEach(() => initTheme({ colorLevel: 3 }));
afterEach(() => {
	while (teardown.length) teardown.pop()?.();
	resetTheme();
	invalidateThemeAdapters();
});

async function boot() {
	const server = await FakeControlPlane.start({
		methods: [...DEFAULT_METHODS, "sessions.tree", "sessions.rewind"],
	});
	teardown.push(() => server.stop());
	const key = newSessionKey(CWD);
	let rewound = false;
	server.respondWith("sessions.active.list", { sessions: [] });
	server.respondWith("exec.approvals.get", { approvals: [] });
	server.respondWith("sessions.list", { sessions: [], total: 0 });
	server.onMethod("chat.history", () => ({
		messages: rewound ? [] : [{ id: "u1", role: "user", content: PROMPT }],
	}));
	server.respondWith("sessions.tree", {
		sessionKey: key,
		entries: [
			{ id: "u1", type: "message", role: "user", isActive: true, rewindable: true, text: PROMPT },
		],
		totalEntries: 1,
	});
	server.onMethod("sessions.rewind", (params: { dryRun: boolean }) => {
		if (!params.dryRun) rewound = true;
		return {
			sessionKey: key,
			entryId: "u1",
			prompt: PROMPT,
			restoreFiles: false,
			restoredPaths: [],
			confirmationToken: "rewind-first-turn",
		};
	});
	server.onMethod("chat.send", () => ({ runId: "retry-run", sessionKey: key }));
	const app = new AppShell({
		url: server.url,
		cwd: CWD,
		sessionKey: key,
		terminal: new MemoryTerminal(),
		client: new ControlPlaneClient({ url: server.url }),
		readBranch: async () => null,
	});
	teardown.push(() => app.stop());
	await app.start();
	app.session.lastRunOutcome = "error";
	return { app, server, key };
}

describe("retry delivery through AppShell", () => {
	test("clears the recovery draft only after an acknowledged run", async () => {
		const { app, server, key } = await boot();
		await app.submit("/retry");
		expect(app.editor.getExpandedText()).toBe("");
		expect(app.store.drafts.get(key) ?? "").toBe("");
		expect(app.session.activeRunId).toBe("retry-run");
		expect(server.requestsFor("chat.send")).toHaveLength(1);
	});

	test("a rejected resend after a successful first-turn rewind retains both recovery drafts", async () => {
		const { app, server, key } = await boot();
		server.failWith("chat.send", "CONFLICT", "refused");
		await app.submit("/retry");
		expect(app.editor.getExpandedText()).toBe(PROMPT);
		expect(app.store.drafts.get(key)).toBe(PROMPT);
		expect(app.session.busy).toBe(false);
		expect(app.store.queue.items(key)).toHaveLength(0);
		server.respondWith("chat.send", { runId: "accepted-after-review", sessionKey: key });
		expect(await app.sendPrompt(PROMPT)).toBe("accepted");
	});

	test("a lost transport receipt retains identity across reconnect without duplicate submission", async () => {
		const { app, server, key } = await boot();
		server.onMethod("chat.send", (_params: unknown, ctx: MethodContext) => {
			ctx.socket.close(1012, "receipt lost");
			return NO_RESPONSE;
		});
		await app.submit("/retry");
		const item = app.store.queue.items(key)[0];
		expect(item.submission?.requestId).toBe(server.requestsFor("chat.send")[0].id);
		expect(app.editor.getExpandedText()).toBe(PROMPT);
		server.respondWith("chat.send", { runId: "must-not-replay", sessionKey: key });
		await app.client.connect();
		await app.sessions.resync();
		await app.drainQueue(key);
		expect(server.requestsFor("chat.send")).toHaveLength(1);
		expect(app.store.queue.items(key)[0]).toBe(item);
	});

	test("an acknowledged recovery send cannot discard a newer composer draft", async () => {
		const { app, server, key } = await boot();
		const receipt = Promise.withResolvers<{ runId: string; sessionKey: string }>();
		server.onMethod("chat.send", () => receipt.promise);
		const retry = app.submit("/retry");
		await server.waitForRequest("chat.send");
		app.editor.setText("a new correction");
		receipt.resolve({ runId: "retry-run", sessionKey: key });
		await retry;
		expect(app.editor.getExpandedText()).toBe("a new correction");
		expect(app.session.activeRunId).toBe("retry-run");
	});

	for (const receipt of ["unknown", "malformed"] as const) {
		test(`${receipt} resend retains its fixed identity and never automatically resends`, async () => {
			const { app, server, key } = await boot();
			server.onMethod("chat.send", () =>
				receipt === "unknown"
					? errorResult("UNAVAILABLE", "no receipt", {
							retrySafe: false,
							runId: "possibly-accepted",
						})
					: { runId: "", sessionKey: key },
			);
			await app.submit("/retry");
			const item = app.store.queue.items(key)[0];
			expect(item.state).toBe("needs-review");
			expect(item.submission?.requestId).toBe(server.requestsFor("chat.send")[0].id);
			if (receipt === "unknown") expect(item.submission?.runId).toBe("possibly-accepted");
			expect(app.editor.getExpandedText()).toBe(PROMPT);
			expect(app.store.drafts.get(key)).toBe(PROMPT);
			await app.drainQueue(key);
			await app.sessions.resync();
			await app.submit("/retry --force");
			expect(await app.sendPrompt(PROMPT)).toBe("uncertain");
			expect(server.requestsFor("chat.send")).toHaveLength(1);
			expect(app.store.queue.items(key)[0]).toBe(item);
			app.editQueued(item);
			server.respondWith("chat.send", { runId: "reviewed-run", sessionKey: key });
			expect(await app.sendPrompt(PROMPT)).toBe("accepted");
		});
	}

	test("uncertain steering never becomes an automatically draining fallback", async () => {
		const { app, server, key } = await boot();
		app.session.busy = true;
		app.session.activeRunId = "original-run";
		server.onMethod("chat.send", () =>
			errorResult("UNAVAILABLE", "no receipt", {
				retrySafe: false,
				runId: "uncertain-steer",
			}),
		);
		expect(await app.sendPrompt("a correction", { mode: "steer" })).toBe("uncertain");
		app.session.busy = false;
		await app.drainQueue(key);
		expect(server.requestsFor("chat.send")).toHaveLength(1);
		expect(app.store.queue.items(key)[0].submission?.runId).toBe("uncertain-steer");
	});
});

describe("explicit directory-bound navigation", () => {
	test("refusal preserves focus, the draft and native history without submitting", async () => {
		const { app, server, key } = await boot();
		app.editor.setText("keep my draft");
		const before = app.session.blocks.filter((block) => block.kind === "user");
		for (const foreign of [
			`agent:default:tui:local:dm:${cwdSessionTag("/other")}-saved`,
			"agent:default:tui:local:dm:legacy-untagged",
		]) {
			await app.submit(`/resume ${foreign}`);
			expect(app.sessionKey).toBe(key);
			expect(app.editor.getExpandedText()).toBe("keep my draft");
			expect(app.session.blocks.filter((block) => block.kind === "user")).toEqual(before);
			expect(app.store.sessions.has(foreign)).toBe(false);
		}
		expect(server.requestsFor("chat.send")).toHaveLength(0);
	});
});
