import { afterEach, describe, expect, test } from "bun:test";
import { describeOmpError } from "../../src/commands/omp.ts";
import {
	DEFAULT_METHODS,
	installOmpFixtures,
	OMP_FAKE_EVENTS,
	OMP_FAKE_METHODS,
} from "../../src/dev/fake-server.ts";
import {
	ControlPlaneError,
	NotConnectedError,
	RequestTimeoutError,
} from "../../src/protocol/errors.ts";
import { METHOD } from "../../src/protocol/methods.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

const harnesses: Harness[] = [];
afterEach(() => {
	for (const harness of harnesses.splice(0)) harness.stop();
});

async function harness(options: { methods?: readonly string[]; available?: boolean } = {}) {
	const h = await createHarness({
		methods: [...(options.methods ?? OMP_FAKE_METHODS)],
		events: [...OMP_FAKE_EVENTS],
		cwd: "/work/lemon",
	});
	harnesses.push(h);
	const fake = installOmpFixtures(h.server, { available: options.available });
	return { ...h, fake };
}

describe("/omp", () => {
	test("run starts a session in the TUI's working directory", async () => {
		const h = await harness();
		await h.run("/omp run fix the   flaky test");
		expect(h.server.requestsFor(METHOD.ompSessionsStart).map((frame) => frame.params)).toEqual([
			{ prompt: "fix the   flaky test", cwd: "/work/lemon" },
		]);
		expect(h.host.last?.level).toBe("info");
		expect(h.host.last?.text).toMatch(/^omp started omp_fake\d+ in lemon · running/);
		expect(h.store.omp.sessions().some((session) => session.title === "fix the   flaky test")).toBe(
			true,
		);
	});

	test("run passes approval and isolation flags without changing the prompt", async () => {
		const h = await harness();
		await h.run("/omp run --approval-mode write --isolate fix   this");
		expect(h.server.requestsFor(METHOD.ompSessionsStart)[0]?.params).toEqual({
			prompt: "fix   this",
			cwd: "/work/lemon",
			approvalMode: "write",
			isolate: true,
		});
	});

	test("run without a prompt prints usage and sends nothing", async () => {
		const h = await harness();
		await h.run("/omp run   ");
		expect(h.host.last?.text).toContain("usage: /omp [run [--approval-mode");
		expect(h.host.last?.level).toBe("warning");
		expect(h.server.requestsFor(METHOD.ompSessionsStart)).toHaveLength(0);
	});

	test("run refuses when omp.status says omp is not installed", async () => {
		const h = await harness({ available: false });
		await h.run("/omp status");
		await h.run("/omp run hello");
		expect(h.host.last).toEqual({
			text: "/omp run: omp is not installed on the daemon host",
			level: "warning",
		});
		expect(h.server.requestsFor(METHOD.ompSessionsStart)).toHaveLength(0);
	});

	test("a refused start is reported as a failure, not a session", async () => {
		const h = await harness();
		h.server.failWith(METHOD.ompSessionsStart, "CONFLICT", "too many omp sessions");
		await h.run("/omp run hello");
		expect(h.host.last).toEqual({ text: "omp run failed: too many omp sessions", level: "error" });
		expect(h.store.omp.sessions().every((session) => session.title !== "hello")).toBe(true);
	});

	test("an offline start is not queued and says so", async () => {
		const h = await harness();
		h.client.close();
		await h.run("/omp run hello");
		expect(h.host.last).toEqual({
			text: "omp run failed: offline — not sent; reconnect and retry",
			level: "error",
		});
		expect(h.client.queued).toHaveLength(0);
	});

	test("status summarises live sessions with sanitized text", async () => {
		const h = await harness();
		await h.run("/omp status");
		const text = h.host.text;
		expect(text).toContain("omp: 2 live (1 running) · 1 ended");
		expect(text).toContain("▶ omp_3f9a1c2b7d4e · Fix the flaky reconnect test · running");
		expect(text).not.toContain("\u001b");
	});

	test("status reports a failed refresh instead of an empty list", async () => {
		const h = await harness();
		h.server.failWith(METHOD.ompSessionsList, "INTERNAL_ERROR", "boom");
		await h.run("/omp status");
		expect(h.host.last?.level).toBe("warning");
		expect(h.host.last?.text).toContain("could not refresh (omp.sessions.list: boom)");
	});

	test("bare /omp falls back to the status summary without a panel host", async () => {
		const h = await harness();
		await h.run("/omp");
		expect(h.host.text).toContain("omp: 2 live");
	});

	test("unknown subcommands print usage", async () => {
		const h = await harness();
		await h.run("/omp launch now");
		expect(h.host.last?.text).toContain("usage: /omp [run [--approval-mode");
	});

	test("is unavailable on a daemon without omp methods", async () => {
		const h = await harness({ methods: DEFAULT_METHODS });
		await h.run("/omp run hello");
		expect(h.host.last).toEqual({
			text: "/omp is unavailable: daemon does not expose the omp.* methods",
			level: "warning",
		});
	});
});

describe("describeOmpError", () => {
	test("timeouts and retrySafe:false are unknown outcomes", () => {
		expect(describeOmpError(new RequestTimeoutError("omp.sessions.send", 30_000))).toBe(
			"no reply within 30s — outcome unknown; refresh before retrying",
		);
		expect(
			describeOmpError(
				new ControlPlaneError({
					code: "CONFLICT",
					message: "omp did not answer",
					details: { retrySafe: false },
				}),
			),
		).toBe("omp did not answer — outcome unknown; refresh before retrying");
		expect(describeOmpError(new NotConnectedError("omp.sessions.cancel"))).toBe(
			"offline — not sent; reconnect and retry",
		);
		expect(
			describeOmpError(new ControlPlaneError({ code: "CONFLICT", message: "bad\u001b[2Jthing" })),
		).toBe("badthing");
	});
});
