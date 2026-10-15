import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import {
	buildComposerFacts,
	renderGauge,
	renderStatusLine,
	StatusBar,
	type StatusBarData,
	shortModel,
} from "../../src/ui/components/status-bar.ts";
import { getTheme, initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { stripAnsi } from "../helpers/memory-terminal.ts";
import { waitFor } from "../helpers/wait.ts";

function data(overrides: Partial<StatusBarData> = {}): StatusBarData {
	return {
		sessionKey: "tui-20260817T120000",
		model: "anthropic:claude-sonnet-4",
		contextTokens: 48_000,
		contextWindow: 200_000,
		branch: "main *",
		sessionCount: 3,
		busy: false,
		unread: 2,
		approvals: 1,
		connection: "online",
		mode: "queue",
		thinking: "high",
		engine: "codex",
		queued: 0,
		...overrides,
	};
}

beforeEach(() => {
	initTheme({ colorLevel: 3 });
});

afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

describe("the gauge", () => {
	test("renders bar, percentage and both numbers", () => {
		expect(renderGauge(48_000, 200_000)).toBe("[▓▓░░░░░░] 24% 48k/200k");
	});

	test("saturates rather than overflowing", () => {
		expect(renderGauge(500_000, 200_000)).toContain("100%");
		expect(renderGauge(500_000, 200_000)).toContain("▓▓▓▓▓▓▓▓");
	});

	test("shows the raw count when no window is known", () => {
		expect(renderGauge(12_500, undefined)).toBe("ctx 13k");
	});

	test("shows nothing invented when neither is known", () => {
		expect(renderGauge(undefined, undefined)).toBe("ctx —");
	});

	test("uses ASCII glyphs under the ASCII preset", () => {
		initTheme({ colorLevel: 3, symbolPreset: "ascii" });
		expect(renderGauge(100_000, 200_000)).toBe("[####----] 50% 100k/200k");
	});

	test("aggregate tokens are labelled as usage and get no bar", () => {
		// Today's total across every session is not a measure of this conversation,
		// so it must not be drawn inside something the user reads as a budget.
		expect(renderGauge(48_000, 200_000, "aggregate")).toBe("use 48k");
	});

	test("aggregate with nothing counted yet still says what it is", () => {
		expect(renderGauge(undefined, 200_000, "aggregate")).toBe("use —");
	});
});

describe("the gauge segment", () => {
	test("a session's own context earns the bar", () => {
		const line = stripAnsi(
			renderStatusLine(data({ contextTokens: 48_000, contextSource: "context" }), 200),
		);
		expect(line).toContain("48k/200k");
	});

	test("today's aggregate does not", () => {
		const line = stripAnsi(
			renderStatusLine(data({ contextTokens: 48_000, contextSource: "aggregate" }), 200),
		);
		expect(line).toContain("use 48k");
		expect(line).not.toContain("48k/200k");
	});

	test("the segment stays pinned even at a width that drops everything else", () => {
		const line = stripAnsi(renderStatusLine(data({ contextSource: "aggregate" }), 30));
		expect(line).toContain("use 48k");
	});
});

describe("the omp badge", () => {
	test("appears only while omp delegates are running, as a clickable composer fact", () => {
		expect(stripAnsi(renderStatusLine(data(), 200))).not.toContain("omp");
		expect(stripAnsi(renderStatusLine(data({ ompBusy: 2 }), 200))).toContain("omp 2▶");
		const extras = JSON.stringify(buildComposerFacts(data({ ompBusy: 1 })).extras);
		expect(extras).toContain("omp 1▶");
		expect(extras).toContain("status.omp");
	});
});

describe("model naming", () => {
	test("drops the provider prefix", () => {
		expect(shortModel("anthropic:claude-sonnet-4")).toBe("claude-sonnet-4");
	});

	test("keeps the tail of a very long id", () => {
		const short = shortModel(`vendor:${"x".repeat(60)}`);
		expect(short.length).toBeLessThanOrEqual(28);
		expect(short.startsWith("…")).toBe(true);
	});

	test("says so when there is no model", () => {
		expect(shortModel(undefined)).toBe("no model — /model to choose");
	});
});

describe("breakpoints", () => {
	for (const width of [40, 60, 80, 100, 120]) {
		test(`fits exactly one row at width ${width}`, () => {
			const line = renderStatusLine(data(), width);
			expect(line).not.toContain("\n");
			expect(visibleWidth(line)).toBeLessThanOrEqual(width);
		});
	}

	test("the model and the gauge survive every width", () => {
		for (const width of [40, 60, 80, 100, 120]) {
			const plain = stripAnsi(renderStatusLine(data(), width));
			expect(plain).toContain("claude-sonnet-4");
			expect(plain).toContain("24%");
		}
	});

	test("wider terminals show strictly more", () => {
		const narrow = stripAnsi(renderStatusLine(data(), 60));
		const wide = stripAnsi(renderStatusLine(data(), 120));
		expect(wide.length).toBeGreaterThan(narrow.length);
		expect(wide).toContain("main *");
		expect(wide).toContain("3 sessions");
		// The session key is the first thing to go.
		expect(narrow).not.toContain("tui-20260817T120000");
	});

	test("a broken connection outranks the optional segments", () => {
		const plain = stripAnsi(renderStatusLine(data({ connection: "reconnecting", queued: 2 }), 60));
		expect(plain).toContain("reconnecting… · 2 queued");
	});

	test("pending approvals are shown even when the row is tight", () => {
		const plain = stripAnsi(renderStatusLine(data({ approvals: 2 }), 60));
		expect(plain).toContain("2 approvals");
	});

	test("busy shows the engine", () => {
		const plain = stripAnsi(renderStatusLine(data({ busy: true }), 120));
		expect(plain).toContain("codex working");
	});

	test("run usage and cost are separate from the context measurement", () => {
		const plain = stripAnsi(renderStatusLine(data({ runTokens: 86_000, runCostUsd: 0.125 }), 200));
		expect(plain).toContain("24% 48k/200k");
		expect(plain).toContain("last 86k tok $0.13");
		expect(stripAnsi(renderStatusLine(data({ runCostUsd: Number.NaN }), 200))).not.toContain("$");
	});

	test("busy composer exposes submission mode and interrupt before optional branch metadata", () => {
		const plain = stripAnsi(
			renderStatusLine(data({ busy: true, mode: "steer", pendingPrompts: 2 }), 120),
		);
		expect(plain).toContain("enter:steer");
		expect(plain).toContain("esc:stop");
		expect(plain).toContain("2 queued");
	});
});

describe("sessions off screen", () => {
	const line = (overrides: Partial<StatusBarData>) =>
		stripAnsi(renderStatusLine(data(overrides), 120));

	test("counts the sessions that are working somewhere else", () => {
		expect(line({ busy: false, busySessions: 1 })).toContain("3 sessions ●1");
		expect(line({ busy: true, busySessions: 2 })).toContain("3 sessions ●2");
	});

	test("says nothing extra when the session on screen is the only one working", () => {
		expect(line({ busy: true, busySessions: 1 })).toContain("3 sessions");
		expect(line({ busy: true, busySessions: 1 })).not.toContain("●");
		expect(line({ busy: false, busySessions: 0 })).not.toContain("●");
	});

	test("a single session never grows the segment", () => {
		expect(line({ sessionCount: 1, busySessions: 1 })).not.toContain("sessions");
	});
});

describe("plan mode", () => {
	test("an active plan mode leads the row in the accent colour", () => {
		const line = renderStatusLine(data({ planMode: "plan" }), 120);
		expect(stripAnsi(line).startsWith("plan · claude-sonnet-4")).toBe(true);
		expect(line).toContain(getTheme().fg("accent", "plan"));
	});

	test("code mode and an unknown mode show nothing", () => {
		for (const planMode of ["code", undefined] as const) {
			const plain = stripAnsi(renderStatusLine(data({ planMode }), 200));
			expect(plain.startsWith("claude-sonnet-4")).toBe(true);
			expect(plain.split(" · ")).not.toContain("plan");
		}
	});

	test("the indicator outlasts the optional segments on a tight row", () => {
		const plain = stripAnsi(renderStatusLine(data({ planMode: "plan", approvals: 2 }), 60));
		expect(plain).toContain("plan · claude-sonnet-4");
		expect(visibleWidth(plain)).toBeLessThanOrEqual(60);
	});

	test("the TSP composer chrome leads its facts with plan and drops it on exit", () => {
		let planMode: StatusBarData["planMode"] = "plan";
		const bar = new StatusBar({ data: () => data({ planMode }) });
		const before = bar.describeComposerFacts();
		const fact = before.extras.c?.[0];
		expect(fact).toMatchObject({
			k: "seg",
			key: "plan",
			p: {
				role: "omp.composer.fact",
				priority: 95,
				title: "Plan mode: read-only until you approve a proposed plan",
			},
		});
		expect(JSON.stringify(fact)).toContain('"t":"plan"');
		planMode = "code";
		const after = bar.describeComposerFacts();
		expect(after).not.toBe(before);
		expect((after.extras.c ?? []).map((seg) => ("k" in seg ? seg.key : undefined))).not.toContain(
			"plan",
		);
	});
});

describe("the component", () => {
	test("returns the same array while nothing changed", () => {
		const bar = new StatusBar({ data: () => data() });
		const first = bar.render(100);
		expect(bar.render(100)).toBe(first);
	});

	test("returns a fresh array when an input changed", () => {
		let busy = false;
		const bar = new StatusBar({ data: () => data({ busy }) });
		const first = bar.render(100);
		busy = true;
		bar.invalidate();
		expect(bar.render(100)).not.toBe(first);
	});

	test("polls the branch and repaints when it moves", async () => {
		let branch = "main";
		let changes = 0;
		const bar = new StatusBar({
			data: () => data({ branch: undefined }),
			cwd: "/tmp",
			readBranch: async () => branch,
			onChange: () => {
				changes += 1;
			},
			pollMs: 5,
		});
		bar.start();
		await waitFor(() => changes > 0, { what: "the first branch read" });
		expect(stripAnsi(bar.render(120)[0])).toContain("main");

		branch = "feature *";
		await waitFor(() => stripAnsi(bar.render(120)[0]).includes("feature *"), {
			what: "the branch to update",
		});
		bar.dispose();
	});

	test("a disposed bar stops polling", async () => {
		let reads = 0;
		const bar = new StatusBar({
			data: () => data(),
			cwd: "/tmp",
			readBranch: async () => {
				reads += 1;
				return "main";
			},
			pollMs: 5,
		});
		bar.start();
		await waitFor(() => reads > 0, { what: "a first read" });
		bar.dispose();
		const seen = reads;
		await Bun.sleep(30);
		expect(reads).toBe(seen);
	});
});

describe("the TSP composer facts", () => {
	const factKeys = (facts: ReturnType<typeof buildComposerFacts>) =>
		(facts.extras.c ?? []).map((seg) => ("k" in seg ? seg.key : undefined));

	test("a native terminal draws no status strip", () => {
		const bar = new StatusBar({ data: () => data() });
		expect(bar.describe().p).toMatchObject({ hidden: true });
	});

	test("the context meter reads this session's context and never the daily aggregate", () => {
		const own = buildComposerFacts(data({ contextSource: "context" }));
		expect(own.context?.p).toMatchObject({
			role: "omp.composer.context",
			value: 0.24,
			label: "24%",
			total: "200k",
		});
		expect(factKeys(own)).not.toContain("context");

		const aggregate = buildComposerFacts(data({ contextSource: "aggregate" }));
		expect(aggregate.context).toBeUndefined();
		expect(factKeys(aggregate)).toContain("context");
	});

	test("model, activity, thinking and usage leave the facts for their own controls", () => {
		const facts = buildComposerFacts(data({ busy: true, runTokens: 12_000, runCostUsd: 0.5 }));
		expect(facts.model.map((span) => span.t).join("")).toBe("claude-sonnet-4");
		expect(facts.usage?.p).toMatchObject({
			role: "omp.composer.usage",
			text: "last 12k tok $0.50",
		});
		expect(factKeys(facts)).toEqual([
			"approvals",
			"branch",
			"unread",
			"sessions",
			"mode",
			"session",
			"engine",
		]);
	});

	test("the same facts object comes back while nothing changed, and clicks reach the host", () => {
		const actions: string[] = [];
		const bar = new StatusBar({
			data: () => data(),
			onNativeAction: (action) => actions.push(action),
		});
		expect(bar.describeComposerFacts()).toBe(bar.describeComposerFacts());
		for (const act of ["status.queue", "status.unknown", "thinking.select"]) {
			bar.handleNativeEvent({ type: "action", key: "", act, mods: [] });
		}
		expect(actions).toEqual(["queue"]);
	});
});
