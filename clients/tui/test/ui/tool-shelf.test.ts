/**
 * Shelf merging, barriers, and the sealing contract that keeps a re-shaping
 * block out of native scrollback.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import { fixtureBlock, fixtureByName } from "../../src/dev/fixtures/tool-fixtures.ts";
import { SessionStore } from "../../src/store/session-store.ts";
import { resetBlockIds } from "../../src/store/transcript-model.ts";
import {
	planToolShelves,
	SHELF_MERGE_THRESHOLD,
	ToolShelfComponent,
} from "../../src/ui/components/tool-shelf.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import type { ToolCardState } from "../../src/ui/tool-view.ts";
import { renderPlain } from "../helpers/memory-terminal.ts";

const NOW = 1_755_400_000_000;

beforeEach(() => {
	resetBlockIds();
	initTheme({ colorLevel: 3 });
});

afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

function shelfWith(entries: Array<[string, ToolCardState]>): ToolShelfComponent {
	const shelf = new ToolShelfComponent({ now: () => NOW });
	for (const [name, state] of entries) {
		const fixture = fixtureByName(name);
		if (!fixture) throw new Error(`no fixture ${name}`);
		shelf.add(fixtureBlock(fixture, state, { at: NOW - 2400 }));
	}
	return shelf;
}

describe("planToolShelves", () => {
	test("groups maximal runs of consecutive tool blocks", () => {
		const session = new SessionStore("t");
		const tool = (id: string) =>
			session.upsertTool({ id, kind: "tool", title: id, detail: null }, "completed", {
				runId: "r",
				ok: true,
			});
		session.addUser("go");
		tool("a");
		tool("b");
		session.addNotice("something happened");
		tool("c");

		const groups = planToolShelves(session.blocks);
		expect(groups.length).toBe(2);
		expect(groups[0]?.map((block) => block.actionId)).toEqual(["a", "b"]);
		expect(groups[1]?.map((block) => block.actionId)).toEqual(["c"]);
	});

	test("a transcript with no tools plans no shelves", () => {
		const session = new SessionStore("t");
		session.addUser("hello");
		session.addNotice("connected");
		expect(planToolShelves(session.blocks)).toEqual([]);
	});
});

describe("merging", () => {
	test("a lone completed tool keeps its full card", () => {
		const shelf = shelfWith([["bash", "success"]]);
		expect(shelf.size).toBe(1);
		expect(shelf.render(120).length).toBeGreaterThan(1);
		expect(shelf.cards[0]?.compact).toBe(false);
	});

	test("a run of completed tools merges to one line each", () => {
		const shelf = shelfWith([
			["read", "success"],
			["grep", "success"],
			["find", "success"],
		]);
		const lines = shelf.render(120);
		expect(lines.length).toBe(3);
		const text = renderPlain(lines);
		expect(text).toContain("read:");
		expect(text).toContain("grep: upsertTool");
		expect(text).toContain("find: *.test.ts");
	});

	test("merging starts exactly at the threshold", () => {
		expect(SHELF_MERGE_THRESHOLD).toBe(2);
		const shelf = shelfWith([["read", "success"]]);
		expect(shelf.cards[0]?.compact).toBe(false);
		const grep = fixtureByName("grep");
		if (!grep) throw new Error("no grep fixture");
		shelf.add(fixtureBlock(grep, "success", { at: NOW - 2400 }));
		expect(shelf.cards[0]?.compact).toBe(true);
		expect(shelf.cards[1]?.compact).toBe(true);
	});

	test("a still-running entry keeps its card while its finished siblings merge", () => {
		const shelf = shelfWith([
			["read", "success"],
			["grep", "success"],
			["bash", "running"],
		]);
		expect(shelf.cards[0]?.compact).toBe(true);
		expect(shelf.cards[2]?.compact).toBe(false);
		expect(shelf.render(120).length).toBeGreaterThan(3);
	});

	test("an entry merges as soon as its own completion lands", () => {
		const read = fixtureByName("read");
		if (!read) throw new Error("missing fixture");
		const shelf = new ToolShelfComponent({ now: () => NOW });
		shelf.add(fixtureBlock(read, "success", { at: NOW - 2400 }));

		// The live path upserts the same block through its phases, so the card is
		// updated in place rather than replaced.
		const session = new SessionStore("t");
		const action = { id: "cmd-1", kind: "command", title: "`mix test`", detail: null };
		const started = session.upsertTool(action, "started", { runId: "r" });
		shelf.add(started);
		expect(shelf.cards[1]?.compact).toBe(false);

		const done = session.upsertTool(action, "completed", { runId: "r", ok: true });
		expect(done.id).toBe(started.id);
		shelf.update(done);
		expect(shelf.cards[1]?.compact).toBe(true);
	});

	test("every merged line respects the render width", () => {
		const shelf = shelfWith([
			["read", "success"],
			["grep", "success"],
			["webfetch", "success"],
		]);
		for (const width of [24, 40, 80, 120]) {
			for (const line of shelf.render(width)) {
				expect(visibleWidth(line)).toBeLessThanOrEqual(width);
			}
		}
	});
});

describe("sealing", () => {
	test("an open shelf is unfinalized and pins the live region", () => {
		const shelf = shelfWith([
			["read", "success"],
			["grep", "success"],
		]);
		// Both entries are done, but the shelf can still take another and re-shape,
		// so its rows must stay off the tape.
		expect(shelf.isTranscriptBlockFinalized()).toBe(false);
		expect(shelf.isNativeScrollbackLiveRegionPinned()).toBe(true);
		expect(shelf.isDisplaceableBlock()).toBe(true);
	});

	test("sealing finalizes it, unpins the region and refuses new entries", () => {
		const shelf = shelfWith([["read", "success"]]);
		shelf.seal();
		expect(shelf.isTranscriptBlockFinalized()).toBe(true);
		expect(shelf.isNativeScrollbackLiveRegionPinned()).toBe(false);
		expect(shelf.isDisplaceableBlock()).toBe(false);
		expect(shelf.open).toBe(false);

		const grep = fixtureByName("grep");
		if (!grep) throw new Error("no grep fixture");
		expect(shelf.add(fixtureBlock(grep, "success"))).toBeUndefined();
		expect(shelf.size).toBe(1);
	});

	test("sealing is idempotent and bumps the version once", () => {
		const shelf = shelfWith([["read", "success"]]);
		shelf.seal();
		const version = shelf.getTranscriptBlockVersion();
		shelf.seal();
		expect(shelf.getTranscriptBlockVersion()).toBe(version);
	});

	test("a sealed shelf's rows never change again", () => {
		const shelf = shelfWith([
			["read", "success"],
			["grep", "success"],
		]);
		shelf.seal();
		const sealed = renderPlain(shelf.render(120));
		const bash = fixtureByName("bash");
		if (!bash) throw new Error("no bash fixture");
		shelf.add(fixtureBlock(bash, "success"));
		expect(renderPlain(shelf.render(120))).toBe(sealed);
	});
});

describe("render contract", () => {
	test("returns the same array reference while unchanged", () => {
		const shelf = shelfWith([
			["read", "success"],
			["grep", "success"],
		]);
		expect(shelf.render(80)).toBe(shelf.render(80));
	});

	test("an update the card drops leaves the shelf byte-identical", () => {
		const session = new SessionStore("t");
		const action = { id: "cmd-1", kind: "command", title: "`mix test`", detail: null };
		const shelf = new ToolShelfComponent({ now: () => NOW });
		shelf.add(session.upsertTool(action, "started", { runId: "r" }));
		shelf.update(session.upsertTool(action, "completed", { runId: "r", ok: true }));
		const sealed = shelf.render(80);
		const version = shelf.getTranscriptBlockVersion();

		// The store refuses the regression, so the block comes back unchanged; the
		// shelf must not bump its version for a no-op either, or the transcript
		// re-emits rows that never changed.
		shelf.update(session.upsertTool(action, "started", { runId: "r" }));
		expect(shelf.getTranscriptBlockVersion()).toBe(version);
		expect(shelf.render(80)).toBe(sealed);
	});

	test("a new entry produces a fresh array and a higher version", () => {
		const shelf = shelfWith([["read", "success"]]);
		const first = shelf.render(80);
		const version = shelf.getTranscriptBlockVersion();
		const grep = fixtureByName("grep");
		if (!grep) throw new Error("no grep fixture");
		shelf.add(fixtureBlock(grep, "success"));
		expect(shelf.render(80)).not.toBe(first);
		expect(shelf.getTranscriptBlockVersion()).toBeGreaterThan(version);
	});
});
