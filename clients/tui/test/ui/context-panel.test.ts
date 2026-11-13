import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { node } from "@oh-my-pi/pi-tui/native/describe";
import type { DescribeContext, NativeChild, NativeNode } from "@oh-my-pi/pi-tui/native/node";
import { Reconciler } from "@oh-my-pi/pi-tui/native/reconcile";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import {
	estimatedContextFixture,
	reportedContextFixture,
} from "../../src/dev/fixtures/context-fixtures.ts";
import { parseSessionsContext } from "../../src/protocol/context-usage.ts";
import {
	CONTEXT_GRID_CELLS,
	ContextPanelComponent,
	gridCells,
} from "../../src/ui/components/context-panel.ts";
import { buildComposerFacts } from "../../src/ui/components/status-bar.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { renderPlain } from "../helpers/memory-terminal.ts";

type TspKind = Parameters<DescribeContext["supports"]>[0];
interface WireNode {
	k: string;
	c?: readonly WireNode[];
}

beforeEach(() => initTheme({ colorLevel: 3 }));
afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

function panel(raw = reportedContextFixture("s1"), rows = 200) {
	const events = { closed: 0, repaints: 0 };
	const component = new ContextPanelComponent(parseSessionsContext(raw), {
		rows: () => rows,
		close: () => events.closed++,
		repaint: () => events.repaints++,
	});
	return { component, events };
}

function context(kinds: readonly TspKind[]): DescribeContext {
	return {
		cols: 100,
		reduceMotion: false,
		dark: true,
		supports: (kind) => kinds.includes(kind),
		feature: () => false,
	};
}

function nodes(root: NativeChild | null): NativeNode[] {
	if (!root || !("k" in root)) return [];
	return [root, ...(root.c ?? []).flatMap(nodes)];
}

describe("row rendering", () => {
	test("never exceeds the width, at any width", () => {
		for (const raw of [reportedContextFixture("s1"), estimatedContextFixture("s2")]) {
			for (const width of [1, 10, 20, 40, 63, 80, 100, 160]) {
				for (const row of panel(raw).component.render(width)) {
					expect(visibleWidth(row)).toBeLessThanOrEqual(width);
				}
			}
		}
	});

	test("returns the same array while nothing changed and a fresh one after scrolling", () => {
		const { component, events } = panel(reportedContextFixture("s1"), 10);
		const first = component.render(80);
		expect(component.render(80)).toBe(first);
		component.handleInput("j");
		expect(events.repaints).toBe(1);
		const scrolled = component.render(80);
		expect(scrolled).not.toBe(first);
		expect(component.offset).toBe(1);
		component.handleInput("G");
		expect(renderPlain(component.render(80))).toContain("normalized to the reported total");
		component.handleInput("g");
		expect(component.offset).toBe(0);
	});

	test("shows the header, every category, free space and the used total", () => {
		const text = renderPlain(panel().component.render(100));
		expect(text).toContain("claude-sonnet-4-5 · 45.2k/200k tokens (22.6%)");
		expect(text).toContain("provider-reported · live session · 42 messages");
		for (const label of ["System prompt", "Tool definitions", "Tool results", "Summaries"]) {
			expect(text).toContain(label);
		}
		expect(text).toMatch(/Free space\s+154,790\s+77\.4%/);
		expect(text).toMatch(/Used\s+45,210\s+22\.6%/);
		expect(text).toContain(
			"Auto-compaction at 168,000 tokens (84.0%) · 122,790 tokens of headroom",
		);
		expect(text).toContain("Largest contributors");
		expect(text).toContain("read result");
		expect(text).toContain("measured live from the running session");
		expect(text).toContain("estimates (≈4 chars/token) normalized to the reported total");
		expect(text).toContain("Raw estimate before scaling: 41,000 tokens");
	});

	test("labels a pure estimate and an un-itemized overhead honestly", () => {
		const text = renderPlain(panel(estimatedContextFixture("s2")).component.render(80));
		expect(text).toContain("estimated · stored session · 120 messages");
		expect(text).toContain("the total and every split are estimates");
		expect(text).toContain("System prompt and tools (not itemized)");
		expect(text).toContain("never recorded for this session");
	});

	test("the grid colors exactly the used share of the window, one cell per percent", () => {
		const reported = gridCells(parseSessionsContext(reportedContextFixture("s1")));
		expect(reported).toHaveLength(CONTEXT_GRID_CELLS);
		expect(reported.filter((cell) => cell.id !== "free")).toHaveLength(23);
		const estimated = gridCells(parseSessionsContext(estimatedContextFixture("s2")));
		expect(estimated.filter((cell) => cell.id !== "free")).toHaveLength(81);
		expect(estimated.filter((cell) => cell.id === "tool_results")).toHaveLength(40);
	});

	test("the grid follows category shares in order and dims part-covered cells", () => {
		const cells = gridCells(parseSessionsContext(estimatedContextFixture("s2")));
		const order = cells.filter((cell) => cell.id !== "free").map((cell) => cell.id);
		expect(order[0]).toBe("user_messages");
		expect(order.filter((id) => id === "assistant_messages")).toHaveLength(22);
		expect(order.at(-1)).toBe("unattributed");
		// The cell where the last category ends is shared with free space.
		expect(cells.filter((cell) => !cell.full).length).toBeGreaterThan(0);
		const rows = panel(estimatedContextFixture("s2")).component.render(100);
		expect(rows.some((row) => row.includes("\x1b[2m"))).toBe(true);
	});

	test("with no known window the grid shows only composition and no free row", () => {
		const raw = {
			...reportedContextFixture("s1"),
			window: null,
			freeTokens: null,
			percentUsed: null,
		};
		const usage = parseSessionsContext(raw);
		expect(gridCells(usage).filter((cell) => cell.id === "free")).toHaveLength(0);
		const text = renderPlain(panel(raw).component.render(80));
		expect(text).toContain("window unknown");
		expect(text).not.toContain("Free space");
	});

	test("escape, q and ctrl+c close the panel", () => {
		for (const key of ["\x1b", "q", "\x03"]) {
			const { component, events } = panel();
			component.handleInput(key);
			expect(events.closed).toBe(1);
		}
	});
});

describe("native description", () => {
	const full = context(["meter", "table", "kv", "progress", "text", "row", "col", "section"]);

	test("describes semantic meter and tables, not painted rows", () => {
		const { component } = panel();
		const root = component.describe(full);
		expect(root).not.toBeNull();
		const all = nodes(root);
		expect(all.some((node) => node.k === "rows")).toBe(false);
		const meters = all.flatMap((node) => (node.k === "meter" ? [node.p] : []));
		expect(meters).toHaveLength(1);
		expect(meters[0]).toMatchObject({ value: 45_210 / 200_000, label: "23%", total: "200k" });
		// The composer's meter for the same session reads identically.
		const composer = buildComposerFacts({
			sessionKey: "s1",
			contextTokens: 45_210,
			contextWindow: 200_000,
			contextSource: "context",
			sessionCount: 1,
			busy: false,
			busySessions: 0,
			unread: 0,
			approvals: 0,
			connection: "online",
			mode: "queue",
			queued: 0,
		}).context;
		const composerMeter = composer?.k === "meter" ? composer.p : undefined;
		for (const key of ["value", "label", "total", "title", "thresholds"] as const) {
			expect(meters[0]?.[key]).toEqual(composerMeter?.[key]);
		}
		expect(composerMeter?.actions).toEqual({ click: "status.context" });
		const parts = meters[0]?.parts ?? [];
		expect(parts).toHaveLength(9);
		expect(parts.reduce((sum, part) => sum + part.value, 0)).toBeCloseTo(45_210 / 200_000, 6);
		const tables = all.flatMap((node) => (node.k === "table" ? [node.p] : []));
		expect(tables).toHaveLength(2);
		const rows = tables[0]?.rows.map((row) => row.id);
		expect(rows).toEqual([
			"system_prompt",
			"tool_definitions",
			"skills",
			"context_files",
			"memory",
			"user_messages",
			"assistant_messages",
			"tool_results",
			"summaries",
			"free",
			"used",
		]);
		expect(component.nativeOverlay.role).toBe("omp.overlay.context");
	});

	test("keeps the same node reference while unchanged", () => {
		const { component } = panel();
		const first = component.describe(full);
		expect(component.describe(full)).toBe(first);
		component.invalidate();
		expect(component.describe(full)).toBe(first);
	});

	test("degrades to progress without meter support and to rows without tables", () => {
		const { component } = panel();
		const noMeter = nodes(component.describe(context(["table", "kv"])));
		expect(noMeter.some((node) => node.k === "progress")).toBe(true);
		expect(noMeter.some((node) => node.k === "meter")).toBe(false);
		expect(component.describe(context(["meter"]))).toBeNull();
	});

	test("the Close button runs the escape path", () => {
		const { component, events } = panel();
		component.handleNativeEvent({ type: "action", key: "actions/close", act: "close", mods: [] });
		expect(events.closed).toBe(1);
	});

	test("reconciles as a semantic overlay sheet and sends nothing more while unchanged", () => {
		const { component } = panel();
		const reconciler = new Reconciler("test-surface");
		const overlay = node(
			"overlay",
			{ ...component.nativeOverlay, modal: true },
			[component],
			"ov-context",
		);
		const regions = { main: [], dock: [], layer: [overlay] };
		const ops = reconciler.reconcile(regions, full);
		const kinds = new Set<string>();
		const visit = (wire: WireNode) => {
			kinds.add(wire.k);
			for (const child of wire.c ?? []) visit(child);
		};
		for (const op of ops) if (op[0] === "add") visit(op[4]);
		expect(kinds.has("meter")).toBe(true);
		expect(kinds.has("table")).toBe(true);
		expect(kinds.has("rows")).toBe(false);
		expect(reconciler.reconcile(regions, full)).toEqual([]);
	});
});
