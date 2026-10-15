import { afterEach, describe, expect, test } from "bun:test";
import { asArray, asRecord } from "../../src/commands/format.ts";
import { FakeControlPlane } from "../../src/dev/fake-server.ts";
import {
	estimatedContextFixture,
	reportedContextFixture,
} from "../../src/dev/fixtures/context-fixtures.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import {
	CONTEXT_CATEGORY_IDS,
	InvalidContextReceiptError,
	parseSessionsContext,
} from "../../src/protocol/context-usage.ts";
import {
	ControlPlaneError,
	MethodUnavailableError,
	NotConnectedError,
} from "../../src/protocol/errors.ts";
import { ControlPlaneMethods } from "../../src/protocol/methods.ts";

const teardown: Array<() => void> = [];
afterEach(() => {
	while (teardown.length > 0) teardown.pop()?.();
});

/** Fast reconnects and no liveness watchdog, as the client protocol tests use. */
const SOCKET = { minBackoffMs: 10, maxBackoffMs: 40, jitter: 0, minWatchdogWindowMs: 0 };

describe("parseSessionsContext", () => {
	test("reads the contract shape, in fixed category order, summing to the total", () => {
		const usage = parseSessionsContext(reportedContextFixture("s1"));
		expect(usage.sessionKey).toBe("s1");
		expect(usage.live).toBe(true);
		expect(usage.overhead).toBe("live");
		expect(usage.source).toBe("usage");
		expect(usage.model).toEqual({ provider: "anthropic", id: "claude-sonnet-4-5" });
		expect(usage.window).toBe(200_000);
		expect(usage.usedTokens).toBe(45_210);
		expect(usage.freeTokens).toBe(154_790);
		expect(usage.percentUsed).toBe(22.6);
		expect(usage.categories.map((category) => category.id)).toEqual(
			CONTEXT_CATEGORY_IDS.filter((id) => id !== "unattributed"),
		);
		expect(usage.categories.reduce((sum, category) => sum + category.tokens, 0)).toBe(45_210);
		expect(usage.otherTokens).toBe(0);
		expect(usage.autoCompaction).toEqual({
			enabled: true,
			thresholdTokens: 168_000,
			reserveTokens: 32_000,
			headroomTokens: 122_790,
		});
		expect(usage.top[0]).toEqual({ category: "tool_results", label: "read result", tokens: 9_000 });
		expect(usage.messageCount).toBe(42);
	});

	test("keeps the trailing unattributed category when overhead was never recorded", () => {
		const usage = parseSessionsContext(estimatedContextFixture("s2"));
		expect(usage.overhead).toBe("unavailable");
		expect(usage.source).toBe("estimate");
		expect(usage.categories.at(-1)?.id).toBe("unattributed");
		expect(usage.categories.reduce((sum, category) => sum + category.tokens, 0)).toBe(
			usage.usedTokens,
		);
	});

	test("reads the optional session usage block and ignores malformed ones", () => {
		const usage = parseSessionsContext(reportedContextFixture("s1"));
		expect(usage.usage).toEqual({
			tokens: 182_400,
			costUsd: 0.4231,
			input: 120_000,
			output: 14_500,
			cacheRead: 40_000,
			cacheWrite: 7_900,
			assistantMessages: 12,
		});
		expect(parseSessionsContext(estimatedContextFixture("s2")).usage).toBeUndefined();
		const raw = reportedContextFixture("s1");
		raw.usage = { tokens: "lots" };
		expect(parseSessionsContext(raw).usage).toBeUndefined();
	});

	test("drops unknown category ids but keeps their tokens as an honest remainder", () => {
		const raw = reportedContextFixture("s1");
		const known = asArray(raw.categories).map((entry) => {
			const record = asRecord(entry) ?? {};
			return record.id === "tool_results" ? { ...record, tokens: 17_790 } : record;
		});
		raw.categories = [
			{ id: "future_kind", label: "Future", tokens: 1_210, percent: 0.6 },
			...known,
		];
		raw.top = [{ category: "future_kind", label: "future thing", tokens: 50 }];
		const usage = parseSessionsContext(raw);
		expect(usage.categories.map((category) => category.id)).not.toContain("future_kind");
		expect(usage.otherTokens).toBe(1_210);
		expect(usage.top[0]?.category).toBeUndefined();
	});

	test("sanitizes and bounds labels, reordering contributors by size", () => {
		const raw = reportedContextFixture("s1");
		raw.top = [
			{ category: "tool_results", label: "small", tokens: 5 },
			{ category: "tool_results", label: `\x1b]0;evil\x07${"x".repeat(200)}`, tokens: 99 },
		];
		const usage = parseSessionsContext(raw);
		expect(usage.top.map((entry) => entry.tokens)).toEqual([99, 5]);
		expect(usage.top[0]?.label).not.toContain("\x1b");
		expect(usage.top[0]?.label.length).toBeLessThanOrEqual(80);
	});

	test("an unknown window yields no free space, percentages or compaction", () => {
		const raw = reportedContextFixture("s1");
		raw.window = null;
		raw.freeTokens = null;
		raw.percentUsed = null;
		const usage = parseSessionsContext(raw);
		expect(usage.window).toBeNull();
		expect(usage.freeTokens).toBeNull();
		expect(usage.percentUsed).toBeNull();
		expect(usage.autoCompaction).toBeNull();
	});

	test("unknown enum values fall back to the least-claiming variant", () => {
		const raw = { ...reportedContextFixture("s1"), source: "magic", overhead: "psychic" };
		const usage = parseSessionsContext(raw);
		expect(usage.source).toBe("estimate");
		expect(usage.overhead).toBe("unavailable");
	});

	test("a receipt without a session key or total is refused", () => {
		expect(() => parseSessionsContext(null)).toThrow(InvalidContextReceiptError);
		expect(() => parseSessionsContext({ usedTokens: 10 })).toThrow(InvalidContextReceiptError);
		expect(() => parseSessionsContext({ sessionKey: "s1", usedTokens: -1 })).toThrow(
			InvalidContextReceiptError,
		);
	});
});

describe("ControlPlaneMethods.sessionsContext", () => {
	async function connect(methods?: string[]) {
		const server = await FakeControlPlane.start(methods ? { methods } : {});
		const client = new ControlPlaneClient({ url: server.url, socketOptions: SOCKET });
		teardown.push(() => {
			client.close();
			server.stop();
		});
		await client.connect();
		return { server, methods: new ControlPlaneMethods(client) };
	}

	test("sends sessionKey and cwd and returns the parsed receipt", async () => {
		const { server, methods } = await connect();
		server.serveSessionContext({ s1: reportedContextFixture("s1") });
		const usage = await methods.sessionsContext({ sessionKey: "s1", cwd: "/repo" });
		expect(server.requestsFor("sessions.context")[0]?.params).toEqual({
			sessionKey: "s1",
			cwd: "/repo",
		});
		expect(usage.usedTokens).toBe(45_210);
	});

	test("unknown sessions answer NOT_FOUND", async () => {
		const { server, methods } = await connect();
		server.serveSessionContext({});
		const error = await methods
			.sessionsContext({ sessionKey: "fresh", cwd: "/repo" })
			.catch((caught: unknown) => caught);
		expect(ControlPlaneError.is(error, "NOT_FOUND")).toBe(true);
	});

	test("is gated on the advertised method list", async () => {
		const { server, methods } = await connect(["chat.send"]);
		await expect(
			methods.sessionsContext({ sessionKey: "s1", cwd: "/repo" }),
		).rejects.toBeInstanceOf(MethodUnavailableError);
		expect(server.requestsFor("sessions.context")).toHaveLength(0);
	});

	test("is never parked in the offline queue", async () => {
		const client = new ControlPlaneClient({ url: "ws://127.0.0.1:1/ws", socketOptions: SOCKET });
		teardown.push(() => client.close());
		const methods = new ControlPlaneMethods(client);
		await expect(
			methods.sessionsContext({ sessionKey: "s1", cwd: "/repo" }),
		).rejects.toBeInstanceOf(NotConnectedError);
		expect(client.queued).toHaveLength(0);
	});
});
