import { afterEach, describe, expect, test } from "bun:test";
import {
	FakeControlPlane,
	installOmpFixtures,
	OMP_FAKE_EVENTS,
	OMP_FAKE_METHODS,
} from "../../src/dev/fake-server.ts";
import {
	OMP_DISCOVERED_FIXTURES,
	OMP_SESSION_FIXTURES,
	ompSessionWire,
} from "../../src/dev/fixtures/omp-fixtures.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import {
	ControlPlaneError,
	MethodUnavailableError,
	NotConnectedError,
} from "../../src/protocol/errors.ts";
import { ControlPlaneMethods, METHOD } from "../../src/protocol/methods.ts";
import {
	parseOmpDiscovered,
	parseOmpSession,
	parseOmpSessionEvent,
	parseOmpSessions,
	parseOmpStatus,
} from "../../src/protocol/omp.ts";

const teardown: Array<() => void> = [];
afterEach(() => {
	for (const fn of teardown.splice(0)) fn();
});

async function connect(methods: readonly string[] = OMP_FAKE_METHODS) {
	const server = await FakeControlPlane.start({
		methods: [...methods],
		events: [...OMP_FAKE_EVENTS],
	});
	const fake = installOmpFixtures(server);
	const client = new ControlPlaneClient({ url: server.url });
	teardown.push(() => {
		client.close();
		server.stop();
	});
	await client.connect();
	return { server, fake, client, methods: new ControlPlaneMethods(client) };
}

describe("omp wire parsing", () => {
	test("session_wire parses every documented field", () => {
		const session = parseOmpSession(ompSessionWire());
		expect(session).toMatchObject({
			id: "omp_3f9a1c2b7d4e",
			status: "running",
			turns: 3,
			toolCalls: 5,
			contextPercent: 18.4,
			owner: { kind: "operator" },
			usage: { totalTokens: 41_226, cost: 0.0018 },
		});
		expect(session).toMatchObject({
			approvalMode: "write",
			approvals: { approved: 2, denied: 1, expired: 0 },
			worktree: { branch: "omp/fix", kept: true },
		});
		expect(session?.activeTools).toEqual([
			{
				id: "call_9",
				name: "bash",
				intent: "Re-running the reconnect suite",
				startedAt: expect.any(Number),
			},
		]);
		expect(session?.todos.map((todo) => todo.status)).toEqual([
			"completed",
			"completed",
			"in_progress",
			"pending",
		]);
		expect(session?.subagents[0]).toMatchObject({
			id: "Explore1",
			agent: "explore",
			status: "completed",
			description: "Map timer usage",
		});
	});

	test("missing and mistyped fields degrade instead of throwing", () => {
		const session = parseOmpSession({
			id: "omp_x",
			status: "hibernating",
			turns: "three",
			todos: [{ content: 7 }, null, { content: "keep me" }],
			activeTools: "bash",
			usage: [],
			owner: { kind: "agent", sessionKey: 5 },
			exit: { code: "1" },
			approvalMode: 4,
			pendingApprovals: [{ id: 1 }],
			approvals: { approved: "3" },
			worktree: false,
		});
		expect(session).toMatchObject({
			id: "omp_x",
			title: "",
			status: "unknown",
			turns: 0,
			activeTools: [],
			usage: null,
			owner: { kind: "agent", sessionKey: null },
			exit: { code: null, reason: null },
			approvalMode: null,
			pendingApprovals: [],
			approvals: { approved: 0, denied: 0, expired: 0 },
			worktree: null,
		});
		expect(session?.todos).toEqual([{ phase: null, content: "keep me", status: "pending" }]);
		// Prototype keys are not statuses.
		expect(parseOmpSession({ id: "omp_y", status: "constructor" })?.status).toBe("unknown");
	});

	test("rows without an identity are dropped", () => {
		expect(parseOmpSession({ title: "no id" })).toBeUndefined();
		expect(parseOmpSession("omp_x")).toBeUndefined();
		expect(parseOmpSessions([ompSessionWire(), { id: 3 }, null])).toHaveLength(1);
		expect(parseOmpDiscovered({ title: "no omp id" })).toBeUndefined();
		expect(parseOmpDiscovered(OMP_DISCOVERED_FIXTURES[1])).toMatchObject({
			liveId: "omp_3f9a1c2b7d4e",
			lastStatus: "interrupted",
			activeElsewhere: false,
		});
	});

	test("omp.session events and omp.status", () => {
		expect(parseOmpSessionEvent({ reason: "settled", session: ompSessionWire() })?.reason).toBe(
			"settled",
		);
		expect(parseOmpSessionEvent({ reason: "updated", session: {} })).toBeUndefined();
		expect(parseOmpSessionEvent({ session: ompSessionWire() })?.reason).toBe("updated");
		expect(parseOmpStatus({ available: false, reason: "not_installed", live: 0 })).toEqual({
			available: false,
			version: null,
			reason: "not_installed",
			live: 0,
			maxSessions: null,
		});
		expect(parseOmpStatus(null).available).toBe(false);
	});
});

describe("omp method wrappers", () => {
	test("list and discover return parsed rows", async () => {
		const { methods, server } = await connect();
		const list = await methods.ompSessionsList({ includeEnded: true, limit: 50 });
		expect(list.sessions.map((session) => session.id)).toEqual(
			OMP_SESSION_FIXTURES.map((wire) => String(wire.id)),
		);
		expect(server.requestsFor(METHOD.ompSessionsList)[0]?.params).toEqual({
			includeEnded: true,
			limit: 50,
		});
		const discovered = await methods.ompSessionsDiscover({ cwd: "/work/lemon" });
		expect(discovered.sessions).toHaveLength(OMP_DISCOVERED_FIXTURES.length);
	});

	test("start sends prompt and cwd and returns the parsed session", async () => {
		const { methods, server } = await connect();
		const { session } = await methods.ompSessionsStart({ prompt: "do it", cwd: "/work/lemon" });
		expect(session.status).toBe("running");
		expect(server.requestsFor(METHOD.ompSessionsStart)[0]?.params).toEqual({
			prompt: "do it",
			cwd: "/work/lemon",
		});
	});

	test("a send without an acceptance receipt is not success", async () => {
		const { methods, server } = await connect();
		server.respondWith(METHOD.ompSessionsSend, { delivery: "steer" });
		await expect(
			methods.ompSessionsSend({ id: "omp_3f9a1c2b7d4e", message: "hi", mode: "steer" }),
		).rejects.toThrow(/no acceptance receipt/);
		server.respondWith(METHOD.ompSessionsStart, { session: { title: "no id" } });
		await expect(methods.ompSessionsStart({ prompt: "x", cwd: "/" })).rejects.toThrow(
			/returned no session/,
		);
	});

	test("server refusals surface as ControlPlaneError", async () => {
		const { methods } = await connect();
		const error = await methods
			.ompSessionsCancel({ id: "omp_8c21aa90e5f1" })
			.catch((caught: unknown) => caught);
		expect(ControlPlaneError.is(error, "CONFLICT")).toBe(true);
	});

	test("unadvertised omp methods fail locally", async () => {
		const { methods, server } = await connect(
			OMP_FAKE_METHODS.filter((m) => !m.startsWith("omp.")),
		);
		expect(methods.supports(METHOD.ompSessionsList)).toBe(false);
		await expect(methods.ompSessionsList()).rejects.toBeInstanceOf(MethodUnavailableError);
		expect(server.requestsFor(METHOD.ompSessionsList)).toHaveLength(0);
	});

	test("mutations are never parked while offline", async () => {
		const client = new ControlPlaneClient({ url: "ws://127.0.0.1:9/ws" });
		teardown.push(() => client.close());
		const methods = new ControlPlaneMethods(client);
		for (const call of [
			() => methods.ompSessionsStart({ prompt: "x", cwd: "/" }),
			() => methods.ompSessionsSend({ id: "omp_a", message: "x" }),
			() => methods.ompSessionsCancel({ id: "omp_a" }),
			() => methods.ompSessionsClose({ id: "omp_a" }),
			() => methods.ompSessionsResume({ ompSessionId: "01a", cwd: "/" }),
		]) {
			await expect(call()).rejects.toBeInstanceOf(NotConnectedError);
		}
		expect(client.queued).toHaveLength(0);
	});

	test("the client demuxes omp.session events", async () => {
		const { server, client } = await connect();
		const received = client.events.waitFor("omp.session", 2000);
		server.pushEvent("omp.session", { reason: "started", session: ompSessionWire() });
		expect(parseOmpSessionEvent(await received)?.session.id).toBe("omp_3f9a1c2b7d4e");
	});
});
