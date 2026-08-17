/**
 * Card rendering across the four lifecycle states, plus the render-contract
 * obligations the transcript container depends on: finalization, monotone
 * versions, same-array memoization, and never exceeding the render width.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import {
	fixtureBlock,
	fixtureByName,
	TOOL_FIXTURES,
} from "../../src/dev/fixtures/tool-fixtures.ts";
import { resetBlockIds } from "../../src/store/transcript-model.ts";
import { AccordionComponent, accordionSettings } from "../../src/ui/components/accordion.ts";
import {
	formatElapsed,
	sharedSpinnerFrame,
	ToolCardComponent,
} from "../../src/ui/components/tool-card.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import type { ToolCardState } from "../../src/ui/tool-view.ts";
import { renderPlain } from "../helpers/memory-terminal.ts";

const STATES: ToolCardState[] = ["streaming", "running", "success", "error"];
const NOW = 1_755_400_000_000;

beforeEach(() => {
	resetBlockIds();
	accordionSettings.reset();
	initTheme({ colorLevel: 3 });
});

afterEach(() => {
	accordionSettings.reset();
	resetTheme();
	invalidateThemeAdapters();
});

function card(name: string, state: ToolCardState): ToolCardComponent {
	const fixture = fixtureByName(name);
	if (!fixture) throw new Error(`no fixture ${name}`);
	return new ToolCardComponent(fixtureBlock(fixture, state, { at: NOW - 2400 }), {
		now: () => NOW,
	});
}

describe("lifecycle rendering", () => {
	test("every fixture renders in every state without exceeding the width", () => {
		for (const fixture of TOOL_FIXTURES) {
			for (const state of STATES) {
				for (const width of [40, 80, 120]) {
					const component = new ToolCardComponent(
						fixtureBlock(fixture, state, { at: NOW - 2400 }),
						{ now: () => NOW },
					);
					const lines = component.render(width);
					expect(lines.length).toBeGreaterThan(0);
					for (const line of lines) {
						expect(visibleWidth(line)).toBeLessThanOrEqual(width);
					}
				}
			}
		}
	});

	test("the header carries the state icon and the title", () => {
		expect(renderPlain(card("bash", "success").render(80))).toContain("✓ `ls -la clients/tui`");
		expect(renderPlain(card("bash", "error").render(80))).toContain("✗ `ls -la clients/tui`");
		// A live card shows a spinner frame rather than a verdict.
		const running = renderPlain(card("bash", "running").render(80)).split("\n")[0] ?? "";
		expect(running).not.toContain("✓");
		expect(running).not.toContain("✗");
		expect(running).toContain("`ls -la clients/tui`");
	});

	test("subagents and reasoning get their own completed glyph", () => {
		expect(renderPlain(card("task", "success").render(80))).toContain("◈ task(codex)");
		expect(renderPlain(card("reasoning", "success").render(80)).startsWith("✻")).toBe(true);
	});

	test("streaming shows the header alone — nothing is known yet", () => {
		const lines = card("read", "streaming").render(80);
		expect(lines.length).toBe(1);
		expect(renderPlain(lines)).toContain("read:");
	});

	test("the body comes from the tool's formatter", () => {
		expect(renderPlain(card("grep", "success").render(80))).toContain("2 matches in 2 files");
		expect(renderPlain(card("bash", "success").render(120))).toContain("drwxr-xr-x");
	});

	test("an edit renders a colourised diff in place of the formatter's plain one", () => {
		const text = renderPlain(card("edit", "success").render(120));
		expect(text).toContain("-1│");
		// The replacement's `+` row inherits the removed row's number, so its
		// gutter is blanked; the inserted lines below it carry their own.
		expect(text).toContain("+4│");
		expect(text).toContain("AgentAction");
	});

	test("an unknown tool still renders a titled card with its result", () => {
		const text = renderPlain(card("unknown", "success").render(80));
		expect(text).toContain("sentry.list_issues");
		expect(text).toContain("LEMON-91");
	});
});

describe("elapsed time", () => {
	test("formats sub-second, second and minute scales", () => {
		expect(formatElapsed(420)).toBe("420ms");
		expect(formatElapsed(2400)).toBe("2.4s");
		expect(formatElapsed(47_000)).toBe("47s");
		expect(formatElapsed(185_000)).toBe("3m 05s");
	});

	test("freezes at completion — a finalized card's bytes must never change", () => {
		const fixture = fixtureByName("bash");
		if (!fixture) throw new Error("no bash fixture");
		let clock = NOW;
		const component = new ToolCardComponent(fixtureBlock(fixture, "running", { at: NOW - 1000 }), {
			now: () => clock,
		});
		component.update(fixtureBlock(fixture, "success", { at: NOW - 1000 }));
		const sealed = renderPlain(component.render(80));
		clock = NOW + 60_000;
		component.invalidate();
		expect(renderPlain(component.render(80))).toBe(sealed);
	});

	test("streaming shows no clock at all — nothing has started being measured", () => {
		const header = renderPlain(card("read", "streaming").render(80)).split("\n")[0] ?? "";
		expect(header).not.toMatch(/\d+(\.\d+)?(ms|s)\s*$/);
	});
});

describe("render contract", () => {
	test("a live card is unfinalized; a completed one is finalized", () => {
		expect(card("bash", "running").isTranscriptBlockFinalized()).toBe(false);
		expect(card("bash", "streaming").isTranscriptBlockFinalized()).toBe(false);
		expect(card("bash", "success").isTranscriptBlockFinalized()).toBe(true);
		expect(card("bash", "error").isTranscriptBlockFinalized()).toBe(true);
	});

	test("returns the same array reference while nothing changes", () => {
		const component = card("grep", "success");
		expect(component.render(80)).toBe(component.render(80));
	});

	test("a width change produces a fresh array", () => {
		const component = card("grep", "success");
		const first = component.render(80);
		expect(component.render(100)).not.toBe(first);
	});

	test("the block version rises on every mutation", () => {
		const fixture = fixtureByName("bash");
		if (!fixture) throw new Error("no bash fixture");
		const component = new ToolCardComponent(fixtureBlock(fixture, "running"), { now: () => NOW });
		const before = component.getTranscriptBlockVersion();
		component.update(fixtureBlock(fixture, "success"));
		expect(component.getTranscriptBlockVersion()).toBeGreaterThan(before);
		const afterUpdate = component.getTranscriptBlockVersion();
		component.toggleAccordion();
		expect(component.getTranscriptBlockVersion()).toBeGreaterThan(afterUpdate);
	});

	test("a replayed phase regression leaves a finalized card byte-identical", () => {
		const fixture = fixtureByName("bash");
		if (!fixture) throw new Error("no bash fixture");
		const component = new ToolCardComponent(fixtureBlock(fixture, "running", { at: NOW - 2400 }), {
			now: () => NOW,
		});
		component.update(fixtureBlock(fixture, "success", { at: NOW - 2400 }));
		const sealed = component.render(80);
		const version = component.getTranscriptBlockVersion();

		// A reconnect redelivers `started`/`updated` after the result landed. The
		// card has reported finalized, so its rows may already be in native
		// scrollback — nothing about it may change again.
		for (const state of ["streaming", "running"] as ToolCardState[]) {
			component.update(fixtureBlock(fixture, state, { at: NOW - 2400 }));
			expect(component.isTranscriptBlockFinalized()).toBe(true);
			expect(component.getTranscriptBlockVersion()).toBe(version);
			expect(component.render(80)).toBe(sealed);
		}
	});

	test("never emits more columns than asked, down to a single column", () => {
		for (const fixture of TOOL_FIXTURES) {
			for (const state of STATES) {
				for (const width of [1, 2, 3, 4, 5, 8, 12]) {
					const component = new ToolCardComponent(
						fixtureBlock(fixture, state, { at: NOW - 2400 }),
						{ now: () => NOW },
					);
					for (const line of component.render(width)) {
						expect(visibleWidth(line)).toBeLessThanOrEqual(width);
					}
					component.setCompact(true);
					for (const line of component.render(width)) {
						expect(visibleWidth(line)).toBeLessThanOrEqual(width);
					}
				}
			}
		}
	});

	test("declares no settled rows — a card commits whole or not at all", () => {
		const component = card("bash", "running") as unknown as {
			getTranscriptBlockSettledRows?: () => number;
		};
		expect(component.getTranscriptBlockSettledRows).toBeUndefined();
	});

	test("never animates without a render hook (tests and the gallery stay clean)", () => {
		const component = card("bash", "running");
		const first = component.render(80);
		expect(component.render(80)).toBe(first);
	});

	test("spinner frames are phase-locked to a shared clock", () => {
		expect(sharedSpinnerFrame(10, 0)).toBe(0);
		expect(sharedSpinnerFrame(10, 80)).toBe(1);
		expect(sharedSpinnerFrame(10, 800)).toBe(0);
		expect(sharedSpinnerFrame(0, 800)).toBe(0);
	});
});

describe("accordion integration", () => {
	test("tools expand and reasoning collapses by default", () => {
		expect(card("read", "success").accordion.state).toBe("expanded");
		expect(card("reasoning", "success").accordion.state).toBe("collapsed");
	});

	test("the global override wins over the per-kind default", () => {
		accordionSettings.setOverride("hidden");
		const component = card("read", "success");
		expect(component.accordion.state).toBe("hidden");
		expect(component.render(80).length).toBe(1);
	});

	test("toggling cycles expanded → collapsed → hidden and changes the row count", () => {
		const component = card("bash", "success");
		const expanded = component.render(120).length;
		expect(component.toggleAccordion()).toBe("collapsed");
		expect(component.render(120).length).toBe(2);
		expect(component.toggleAccordion()).toBe("hidden");
		expect(component.render(120).length).toBe(1);
		expect(component.toggleAccordion()).toBe("expanded");
		expect(component.render(120).length).toBe(expanded);
	});
});

describe("compact (shelf) form", () => {
	test("renders exactly one line carrying the icon, title and summary", () => {
		const component = card("grep", "success");
		component.setCompact(true);
		const lines = component.render(80);
		expect(lines.length).toBe(1);
		const text = renderPlain(lines);
		expect(text).toContain("✓");
		expect(text).toContain("grep: upsertTool");
		expect(text).toContain("2 matches");
	});

	test("the compact line respects the width", () => {
		const component = card("bash", "success");
		component.setCompact(true);
		for (const width of [24, 40, 80]) {
			expect(visibleWidth(component.render(width)[0] ?? "")).toBeLessThanOrEqual(width);
		}
	});
});

describe("AccordionComponent", () => {
	test("hidden renders nothing, collapsed one line, expanded everything", () => {
		const lines = ["one", "two", "three"];
		const accordion = new AccordionComponent("expanded");
		accordion.setLines(lines);
		expect(accordion.render(80).length).toBe(3);
		accordion.setState("collapsed");
		expect(accordion.render(80).length).toBe(1);
		expect(renderPlain(accordion.render(80))).toContain("+2 more");
		accordion.setState("hidden");
		expect(accordion.render(80).length).toBe(0);
	});

	test("an empty body renders nothing in any state", () => {
		const accordion = new AccordionComponent("expanded");
		expect(accordion.render(80).length).toBe(0);
		accordion.setState("collapsed");
		expect(accordion.render(80).length).toBe(0);
	});

	test("returns the same array reference while unchanged, and truncates to width", () => {
		const accordion = new AccordionComponent("expanded");
		accordion.setLines(["a long line ".repeat(20)]);
		const first = accordion.render(40);
		expect(accordion.render(40)).toBe(first);
		expect(visibleWidth(first[0] ?? "")).toBeLessThanOrEqual(40);
	});

	test("setting identical lines is a no-op for the version", () => {
		const accordion = new AccordionComponent("expanded");
		accordion.setLines(["a", "b"]);
		const version = accordion.version;
		accordion.setLines(["a", "b"]);
		expect(accordion.version).toBe(version);
		accordion.setLines(["a", "c"]);
		expect(accordion.version).toBeGreaterThan(version);
	});

	test("the indent yields to the width rather than breaching it", () => {
		const accordion = new AccordionComponent("expanded");
		accordion.setLines(["abcdefghijkl", "mnop"]);
		accordion.setSummary("abcdefghijkl");
		for (const state of ["expanded", "collapsed"] as const) {
			accordion.setState(state);
			for (const width of [1, 2, 3, 4, 5, 8, 11]) {
				for (const line of accordion.render(width)) {
					expect(visibleWidth(line)).toBeLessThanOrEqual(width);
				}
			}
		}
	});

	test("the collapsed hint is dropped when it cannot coexist with the summary", () => {
		const accordion = new AccordionComponent("collapsed");
		accordion.setLines(["summary", "a", "b"]);
		accordion.setSummary("summary");
		// Wide enough for both.
		expect(renderPlain(accordion.render(40))).toContain("+2 more");
		// Too narrow: the summary wins, and the row still fits.
		const narrow = accordion.render(8);
		expect(renderPlain(narrow)).not.toContain("more");
		expect(visibleWidth(narrow[0] ?? "")).toBeLessThanOrEqual(8);
	});

	test("cycleOverride walks the global default and back to unset", () => {
		expect(accordionSettings.cycleOverride()).toBe("collapsed");
		expect(accordionSettings.cycleOverride()).toBe("expanded");
		expect(accordionSettings.cycleOverride()).toBeUndefined();
	});
});
