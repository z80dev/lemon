/**
 * Card rendering across the four lifecycle states, plus the render-contract
 * obligations the transcript container depends on: finalization, monotone
 * versions, same-array memoization, and never exceeding the render width.
 */

import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import {
	fixtureBlock,
	fixtureByName,
	TOOL_FIXTURES,
} from "../../src/dev/fixtures/tool-fixtures.ts";
import { SessionStore } from "../../src/store/session-store.ts";
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
import { injectedControl, renderPlain } from "../helpers/memory-terminal.ts";

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
	return new ToolCardComponent(fixtureBlock(fixture, state, { at: NOW - 2400, completedAt: NOW }), {
		now: () => NOW,
	});
}

describe("lifecycle rendering", () => {
	test("every fixture renders in every state without exceeding the width", () => {
		for (const fixture of TOOL_FIXTURES) {
			for (const state of STATES) {
				for (const width of [40, 80, 120]) {
					const component = new ToolCardComponent(
						fixtureBlock(fixture, state, { at: NOW - 2400, completedAt: NOW }),
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

	test("subagents get their own completed glyph", () => {
		expect(renderPlain(card("task", "success").render(80))).toContain("◈ task: audit");
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

	test("an edit renders the tool's own diff, gutter starting at the file's real line", () => {
		const text = renderPlain(card("edit", "success").render(120));
		const rows = text.split("\n");
		// The first diff row is the edit tool's first context line, at line 118.
		const firstDiffRow = rows.find((row) => row.includes("│"));
		expect(firstDiffRow).toContain("118│");
		expect(text).toContain("+121│");
		expect(text).toContain("+122│");
		expect(text).not.toContain(" 1│");
		expect(text).toContain("const kind");
	});

	test("an unknown tool still renders a titled card with its result", () => {
		const text = renderPlain(card("unknown", "success").render(80));
		expect(text).toContain("custom_search");
		expect(text).toContain("tui-1755");
	});
});

describe("elapsed time", () => {
	test("formats sub-second, second and minute scales", () => {
		expect(formatElapsed(420)).toBe("420ms");
		expect(formatElapsed(2400)).toBe("2.4s");
		expect(formatElapsed(47_000)).toBe("47s");
		expect(formatElapsed(185_000)).toBe("3m 05s");
	});

	test("completed tools retain their observed elapsed time after a delayed update and remount", () => {
		let clock = NOW;
		const now = spyOn(Date, "now").mockImplementation(() => clock);
		try {
			for (const outcome of [
				{ name: "read", elapsed: 2, ok: true, details: {} },
				{ name: "edit", elapsed: 8, ok: false, details: {} },
				{ name: "bash", elapsed: 42, ok: false, details: { cancelled: true } },
			]) {
				clock = NOW;
				const session = new SessionStore("elapsed");
				const action = {
					id: outcome.name,
					kind: "tool",
					title: outcome.name,
					detail: { name: outcome.name, args: { path: "file.ts", command: "sleep 10" } },
				};
				const block = session.upsertTool(action, "started");
				const component = new ToolCardComponent(block, { now: () => clock });
				clock += outcome.elapsed;
				session.upsertTool(
					{ ...action, detail: { ...action.detail, result: "receipt", details: outcome.details } },
					"completed",
					{ ok: outcome.ok },
				);

				// Rendering can lag the terminal event, even without a session switch.
				clock += 2000;
				component.update(block);
				const sealed = renderPlain(component.render(120));
				expect(sealed.split("\n")[0]).toEndWith(`${outcome.elapsed}ms`);
				const native = component.describe();
				expect(native).toMatchObject({ k: "tool", p: { took: outcome.elapsed } });
				component.dispose();

				clock += 600_000;
				component.invalidate();
				expect(renderPlain(component.render(120))).toBe(sealed);
				const remounted = new ToolCardComponent(block, { now: () => clock });
				expect(renderPlain(remounted.render(120))).toBe(sealed);
				expect(remounted.describe()).toEqual(native);
				expect(remounted.describe()).toBe(remounted.describe());
				remounted.dispose();
			}
		} finally {
			now.mockRestore();
		}
	});

	test("a live clock advances across streaming, updates and remounts, including a zero start", () => {
		let clock = 0;
		const now = spyOn(Date, "now").mockImplementation(() => clock);
		try {
			const session = new SessionStore("elapsed");
			const action = { id: "read", kind: "tool", title: "read", detail: null };
			const block = session.upsertTool(action, "started");
			clock = 100;
			const component = new ToolCardComponent(block, { now: () => clock });
			expect(renderPlain(component.render(80)).split("\n")[0]).not.toMatch(/\d+(ms|s)\s*$/);
			expect(component.describe().p).not.toHaveProperty("age");

			session.upsertTool(
				{ ...action, detail: { name: "read", args: { path: "file.ts" } } },
				"updated",
			);
			component.update(block);
			expect(renderPlain(component.render(80)).split("\n")[0]).toEndWith("100ms");
			expect(component.describe()).toMatchObject({ k: "tool", p: { age: 100 } });
			clock = 2400;
			component.invalidate();
			expect(renderPlain(component.render(80)).split("\n")[0]).toEndWith("2.4s");
			component.dispose();
			const remounted = new ToolCardComponent(block, { now: () => clock });
			expect(renderPlain(remounted.render(80)).split("\n")[0]).toEndWith("2.4s");
			expect(remounted.describe()).toMatchObject({ k: "tool", p: { age: 2400 } });
			remounted.dispose();
		} finally {
			now.mockRestore();
		}
	});

	test("a completed receipt without an observed start has no row or native duration", () => {
		const session = new SessionStore("receipt");
		const block = session.upsertTool(
			{ id: "receipt", kind: "tool", title: "read", detail: { name: "read", result: "saved" } },
			"completed",
			{ ok: true },
		);
		// A persisted timestamp by itself does not tell us how long a tool ran.
		block.at = NOW - 600_000;
		for (const clock of [NOW, NOW + 600_000]) {
			const component = new ToolCardComponent(block, { now: () => clock });
			component.update(block);
			expect(renderPlain(component.render(80)).split("\n")[0]).not.toMatch(/\d+(ms|s)\s*$/);
			expect(component.describe().p).not.toHaveProperty("took");
			expect(component.describe().p).not.toHaveProperty("age");
			const version = component.getTranscriptBlockVersion();
			component.update({ ...block, phase: "updated" });
			expect(component.isTranscriptBlockFinalized()).toBe(true);
			expect(component.getTranscriptBlockVersion()).toBe(version);
			component.dispose();
		}
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
		component.update(fixtureBlock(fixture, "success", { at: NOW - 2400, completedAt: NOW }));
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
						fixtureBlock(fixture, state, { at: NOW - 2400, completedAt: NOW }),
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

	test("a mutable card does not publish append-only history", () => {
		const component = card("bash", "running") as unknown as {
			transcriptBlockMode?: "appendOnly";
		};
		expect(component.transcriptBlockMode).toBeUndefined();
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
	test("tools expand by default", () => {
		expect(card("read", "success").accordion.state).toBe("expanded");
	});

	test("the global override wins over the per-kind default", () => {
		accordionSettings.setOverride("hidden");
		const component = card("read", "success");
		expect(component.accordion.state).toBe("hidden");
		expect(component.render(80).length).toBe(1);
	});

	test("toggling flips expanded ↔ collapsed and changes the row count", () => {
		const component = card("bash", "success");
		const expanded = component.render(120).length;
		expect(component.toggleAccordion()).toBe("collapsed");
		expect(component.render(120).length).toBe(2);
		expect(component.toggleAccordion()).toBe("expanded");
		expect(component.render(120).length).toBe(expanded);
	});

	test("toggling a card the global override hid opens it fully", () => {
		accordionSettings.setOverride("hidden");
		const component = card("bash", "success");
		expect(component.render(120).length).toBe(1);
		expect(component.toggleAccordion()).toBe("expanded");
		expect(component.render(120).length).toBeGreaterThan(2);
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
		expect(text).toContain("grep: `upsertTool`");
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

describe("hostile receipts", () => {
	test("a bash receipt cannot emit OSC 8/52, retitle the window or clear the screen", () => {
		const hostile =
			"\x1b]0;INJECTED_TITLE\x07\x1b]52;c;SU5KRUNURUQ=\x07\x1b]8;;https://evil.example/\x07click\x1b]8;;\x07\x1b[2J\x1b[Hdone";
		const session = new SessionStore("hostile");
		const block = session.upsertTool(
			{
				id: "bash-hostile",
				kind: "tool",
				title: `cat evil.txt${hostile}`,
				detail: { name: "bash", args: { command: `cat evil.txt${hostile}` }, result: hostile },
			},
			"completed",
			{ ok: false, message: hostile },
		);
		accordionSettings.setOverride("expanded");
		const component = new ToolCardComponent(block, { now: () => NOW });
		expect(renderPlain(component.render(120))).toContain("done");
		expect(injectedControl(component.render(120).join("\n"))).toBeUndefined();
		expect(JSON.stringify(component.describe())).not.toContain("\\u001b");
	});
});
