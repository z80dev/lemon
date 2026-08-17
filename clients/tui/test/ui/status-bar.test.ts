import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import {
	renderGauge,
	renderStatusLine,
	StatusBar,
	type StatusBarData,
	shortModel,
} from "../../src/ui/components/status-bar.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
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
		expect(shortModel(undefined)).toBe("no model");
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
		expect(plain).toContain("reconnecting +2");
	});

	test("pending approvals are shown even when the row is tight", () => {
		const plain = stripAnsi(renderStatusLine(data({ approvals: 2 }), 60));
		expect(plain).toContain("2 approvals");
	});

	test("busy shows the engine", () => {
		const plain = stripAnsi(renderStatusLine(data({ busy: true }), 120));
		expect(plain).toContain("codex working");
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
