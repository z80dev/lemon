import { afterEach, expect, test } from "bun:test";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import type { CommandHost } from "../../src/commands/index.ts";
import { JobsFeed, jobsFailure, panelStatus } from "../../src/commands/jobs.ts";
import { ControlPlaneError, RequestTimeoutError } from "../../src/protocol/errors.ts";
import { InvalidJobsReceiptError, parseProcessJobsList } from "../../src/protocol/jobs.ts";
import type { ControlPlaneMethods } from "../../src/protocol/methods.ts";
import type {
	ProcessJobDetail,
	ProcessJobSummary,
	ProcessJobsCancelResult,
	ProcessJobsListResult,
} from "../../src/protocol/types.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

const KEY = "tui-jobs";
const METHODS = ["process.jobs.list", "process.jobs.inspect", "process.jobs.cancel"];

function job(overrides: Partial<ProcessJobSummary> = {}): ProcessJobSummary {
	return {
		id: "job-1",
		status: "running",
		ownerId: "root-1",
		command: "sleep 60",
		startedAt: 10_000,
		endedAt: null,
		exitCode: null,
		launch: "accepted",
		...overrides,
	};
}

function listing(overrides: Partial<ProcessJobsListResult> = {}): ProcessJobsListResult {
	return {
		sessionKey: KEY,
		live: true,
		rootId: "root-1",
		at: null,
		jobs: [job()],
		agents: [],
		total: 1,
		truncated: false,
		...overrides,
	};
}

function detail(overrides: Partial<ProcessJobDetail> = {}): ProcessJobDetail {
	return {
		...job(),
		cwd: "/work",
		backend: "local",
		pids: [4242],
		output: "building\n",
		outputTruncated: false,
		outputBytes: 9,
		...overrides,
	};
}

interface Stub {
	list: ProcessJobsListResult | Error;
	inspect: ProcessJobDetail | Error;
	cancel: ProcessJobsCancelResult | Error;
	calls: Array<{ method: string; params: unknown }>;
}

function stubMethods(stub: Stub): ControlPlaneMethods {
	const answer = <T>(method: string, params: unknown, value: T | Error): Promise<T> => {
		stub.calls.push({ method, params });
		return value instanceof Error ? Promise.reject(value) : Promise.resolve(value);
	};
	return {
		supports: () => true,
		processJobsList: (params: unknown) => answer("list", params, stub.list),
		processJobsInspect: (params: unknown) =>
			answer(
				"inspect",
				params,
				stub.inspect instanceof Error ? stub.inspect : { sessionKey: KEY, job: stub.inspect },
			),
		processJobsCancel: (params: unknown) => answer("cancel", params, stub.cancel),
	} as unknown as ControlPlaneMethods;
}

function feedFor(stub: Stub, overrides: { canCancel?: boolean } = {}) {
	const notices: Array<[string, string]> = [];
	let closed = 0;
	const feed = new JobsFeed({
		methods: stubMethods(stub),
		sessionKey: KEY,
		canCancel: overrides.canCancel ?? true,
		notify: (text, level) => notices.push([text, level]),
		repaint: () => {},
		close: () => {
			closed += 1;
		},
	});
	return { feed, notices, closed: () => closed };
}

/** Let every already-resolved promise chain run; no wall-clock wait. */
const settled = () => new Promise<void>((resolve) => setImmediate(resolve));

const base = (): Stub => ({
	list: listing(),
	inspect: detail(),
	cancel: {
		sessionKey: KEY,
		jobId: "job-1",
		cancelled: true,
		job: job({ status: "killed", endedAt: 11_000 }),
	},
	calls: [],
});

test("statuses fold into the sheet's four states", () => {
	const states = (status: string, exitCode: number | null = null) =>
		panelStatus(job({ status, exitCode }));
	for (const live of ["queued", "starting", "running", "killing"]) {
		expect(states(live)).toBe("running");
	}
	expect(states("completed", 0)).toBe("completed");
	expect(states("completed", 2)).toBe("failed");
	expect(states("killed")).toBe("cancelled");
	expect(states("canceled")).toBe("cancelled");
	for (const failed of ["error", "lost", "rejected", "expired", "unknown"]) {
		expect(states(failed)).toBe("failed");
	}
});

test("the snapshot splits live from settled jobs and places subagent jobs", () => {
	const { feed } = feedFor(base());
	feed.prime(
		listing({
			jobs: [
				job(),
				job({ id: "job-2", status: "completed", exitCode: 0, endedAt: 12_000 }),
				job({ id: "job-3", ownerId: "child-1", command: "tail -f log" }),
			],
			agents: [{ id: "child-1", parentId: "root-1", name: "reviewer" }],
			total: 3,
		}),
	);
	const snapshot = feed.load();
	expect(snapshot.rootId).toBe("root-1");
	expect(snapshot.running.map((j) => j.id)).toEqual(["job-1", "job-3"]);
	expect(snapshot.recent.map((j) => j.id)).toEqual(["job-2"]);
	expect(snapshot.agents).toEqual([{ id: "reviewer child-1", parentId: "root-1" }]);
	expect(snapshot.running[1]?.ownerId).toBe("reviewer child-1");
	// The root's own jobs keep the real id the sheet compares against rootId.
	expect(snapshot.running[0]?.ownerId).toBe("root-1");
	expect(snapshot.recent[0]?.endTime).toBe(12_000);
});

test("job times are corrected by the daemon's clock", () => {
	const now = Date.now();
	const { feed } = feedFor(base());
	feed.prime(listing({ at: now + 3_600_000, jobs: [job({ startedAt: now + 3_600_000 - 5_000 })] }));
	const started = feed.load().running[0]?.startTime ?? 0;
	expect(Math.abs(started - (now - 5_000))).toBeLessThan(1_000);
});

test("a non-live session reads as empty with an explanation, not as an error", () => {
	const { feed } = feedFor(base());
	feed.prime(listing({ live: false, rootId: null, jobs: [], total: 0 }));
	expect(feed.load().running).toEqual([]);
	expect(feed.note()).toContain("no live runtime");
});

test("inspect fetches the wanted job's detail on the next poll", async () => {
	const stub = base();
	const { feed } = feedFor(stub);
	feed.prime(stub.list as ProcessJobsListResult);
	expect(feed.inspect("job-1")).toBeUndefined();
	await feed.refresh();
	expect(stub.calls.map((c) => c.method)).toEqual(["list", "inspect"]);
	expect(stub.calls[1]?.params).toEqual({ sessionKey: KEY, jobId: "job-1", tailBytes: 16_384 });
	expect(feed.inspect("job-1")).toEqual({
		command: "sleep 60",
		cwd: "/work",
		pids: [4242],
		exitCode: undefined,
		output: "building\n",
	});
});

test("truncated output is flagged in the sheet", async () => {
	const stub = { ...base(), inspect: detail({ outputTruncated: true, output: "tail" }) };
	const { feed } = feedFor(stub);
	feed.prime(stub.list as ProcessJobsListResult);
	feed.inspect("job-1");
	await feed.refresh();
	expect(feed.inspect("job-1")?.output).toBe("[earlier output not shown]\ntail");
});

test("a failed poll keeps the last listing and marks it stale until one succeeds", async () => {
	const stub = base();
	const { feed } = feedFor(stub);
	feed.prime(stub.list as ProcessJobsListResult);
	stub.list = new ControlPlaneError({ code: "UNAVAILABLE", message: "private detail" });
	await feed.refresh();
	expect(feed.load().running.map((j) => j.id)).toEqual(["job-1"]);
	expect(feed.note()).toContain("stale");
	expect(feed.note()).not.toContain("private detail");
	stub.list = listing();
	await feed.refresh();
	expect(feed.note()).toBeUndefined();
});

test("cancel sends one exact request, reports it, and polls again", async () => {
	const stub = base();
	const { feed, notices } = feedFor(stub);
	feed.prime(stub.list as ProcessJobsListResult);
	feed.cancel?.("job-1");
	feed.cancel?.("job-1");
	await settled();
	const cancels = stub.calls.filter((c) => c.method === "cancel");
	expect(cancels).toHaveLength(1);
	expect(cancels[0]?.params).toEqual({ sessionKey: KEY, jobId: "job-1" });
	expect(feed.note()).toContain("cancel requested");
	expect(notices).toEqual([]);
});

test("an unknown cancel outcome is reported and never retried", async () => {
	const stub = base();
	stub.cancel = new ControlPlaneError({
		code: "UNAVAILABLE",
		message: "x",
		details: { reason: "outcome_unknown", retrySafe: false },
	});
	const { feed, notices } = feedFor(stub);
	feed.prime(stub.list as ProcessJobsListResult);
	feed.cancel?.("job-1");
	await settled();
	expect(stub.calls.filter((c) => c.method === "cancel")).toHaveLength(1);
	expect(notices).toHaveLength(1);
	expect(notices[0]?.[0]).toContain("not retried");
	expect(notices[0]?.[1]).toBe("warning");
});

test("a daemon without process.jobs.cancel renders read-only with the reason", () => {
	const { feed } = feedFor(base(), { canCancel: false });
	expect(feed.cancel).toBeUndefined();
	expect(feed.note()).toContain("read-only");
});

test("closing stops the feed and closes the overlay once", () => {
	const { feed, closed } = feedFor(base());
	feed.close();
	feed.close();
	expect(closed()).toBe(1);
});

test("failures map to fixed messages without server text", () => {
	const timeout = jobsFailure("cancel", new RequestTimeoutError("process.jobs.cancel", 15_000));
	expect(timeout[0]).toContain("not retried");
	const conflict = jobsFailure(
		"cancel",
		new ControlPlaneError({ code: "CONFLICT", message: "/Users/alice/secret" }),
	);
	expect(conflict[0]).toBe("That job already finished.");
	expect(jobsFailure("list", new InvalidJobsReceiptError("process.jobs.list"))[1]).toBe("error");
});

test("a malformed list receipt is refused, never read as no jobs", () => {
	expect(() => parseProcessJobsList({ sessionKey: KEY, live: true })).toThrow(
		InvalidJobsReceiptError,
	);
	expect(() => parseProcessJobsList(null)).toThrow(InvalidJobsReceiptError);
	const parsed = parseProcessJobsList({
		sessionKey: KEY,
		live: true,
		jobs: [{ id: "a", status: 5, command: 7 }, { nope: true }],
	});
	expect(parsed.jobs).toEqual([
		{
			id: "a",
			status: "unknown",
			ownerId: null,
			command: null,
			startedAt: null,
			endedAt: null,
			exitCode: null,
			launch: null,
		},
	]);
});

let harness: Harness | undefined;
afterEach(() => {
	harness?.stop();
	harness = undefined;
});

async function boot(): Promise<{ h: Harness; overlays: Component[]; closes: () => number }> {
	const h = await createHarness({ methods: METHODS, sessionKey: KEY, cwd: "/work/project" });
	harness = h;
	const overlays: Component[] = [];
	let closes = 0;
	(h.host as CommandHost).presentOverlay = (build) => {
		overlays.push(
			build({
				close: () => {
					closes += 1;
				},
				repaint: () => {},
				rows: () => 40,
				columns: () => 100,
				tui: undefined as never,
			}),
		);
	};
	return { h, overlays, closes: () => closes };
}

test("/jobs lists the focused session's processes in the sheet and closes on escape", async () => {
	const { h, overlays, closes } = await boot();
	h.server.onMethod("process.jobs.list", () => listing());
	h.server.onMethod("process.jobs.inspect", () => ({ sessionKey: KEY, job: detail() }));
	await h.run("/jobs");
	expect(h.server.requestsFor("process.jobs.list")[0]?.params).toEqual({ sessionKey: KEY });
	expect(overlays).toHaveLength(1);
	const rows = overlays[0]?.render(100).join("\n") ?? "";
	expect(rows).toContain("sleep 60");
	expect(rows).toContain("1 running");
	overlays[0]?.handleInput?.("\x1b");
	expect(closes()).toBe(1);
});

test("/jobs never opens the sheet on a failed query", async () => {
	const { h, overlays } = await boot();
	h.server.failWith("process.jobs.list", "UNAVAILABLE", "/Users/alice/private");
	await h.run("/jobs");
	expect(overlays).toHaveLength(0);
	expect(h.host.last?.level).toBe("warning");
	expect(h.host.text).not.toContain("/Users/alice");
});

test("/jobs is disabled when the daemon lacks the methods", async () => {
	const h = await createHarness({ methods: ["chat.send"], sessionKey: KEY });
	harness = h;
	await h.run("/jobs");
	expect(h.server.requestsFor("process.jobs.list")).toHaveLength(0);
});
