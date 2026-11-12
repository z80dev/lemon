import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { Component, TerminalFramePlan, ViewportSize } from "@oh-my-pi/pi-tui/tui";
import { Container, TUI } from "@oh-my-pi/pi-tui/tui";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import { AssistantMessageComponent } from "../../src/ui/components/assistant-message.ts";
import { TranscriptContainer } from "../../src/ui/components/transcript-container.ts";
import { RowFrameProvider } from "../../src/ui/row-frame-provider.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal, renderPlain } from "../helpers/memory-terminal.ts";
import { waitFor } from "../helpers/wait.ts";

const SIZE = { columns: 80, rows: 6 };

class Rows implements Component {
	renders = 0;
	finalized = true;
	constructor(public rows: string[]) {}
	render(): readonly string[] {
		this.renders++;
		return this.rows;
	}
	isTranscriptBlockFinalized(): boolean {
		return this.finalized;
	}
}

/** Simulates only the writer's acceptance boundary, not retirement decisions. */
function drain(
	provider: RowFrameProvider,
	history: string[],
	size: ViewportSize = SIZE,
): TerminalFramePlan {
	for (let frame = 0; frame < 100; frame++) {
		const plan = provider.renderFrame(size);
		expect(plan.viewport.length).toBeLessThanOrEqual(size.rows);
		if (plan.history === undefined) return plan;
		history.push(...plan.history.rows);
		provider.acknowledgeHistory(plan.history.id);
	}
	throw new Error("history retirement did not converge");
}

function content(rows: readonly string[]): string[] {
	return renderPlain(rows)
		.split("\n")
		.filter((row) => row.trim().length > 0);
}

beforeEach(() => initTheme({ colorLevel: 3 }));
afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

describe("RowFrameProvider history transactions", () => {
	test("offers immutable ordered rows until exact acknowledgement, never the dock", () => {
		const transcript = new TranscriptContainer();
		const first = new Rows(["first", "second"]);
		transcript.addChild(first);
		transcript.addChild(new Rows(["third", "fourth"]));
		const dock = new Rows(["editor"]);
		const provider = new RowFrameProvider(transcript, [new Rows(["banner"])], [dock]);
		const offered = provider.renderFrame(SIZE);
		expect(offered.history?.rows).toEqual(["banner"]);
		expect(provider.renderFrame(SIZE).history).toBe(offered.history);
		provider.acknowledgeHistory(offered.history!.id + 100);
		expect(provider.renderFrame(SIZE).history).toBe(offered.history);
		const history = [...offered.history!.rows];
		provider.acknowledgeHistory(offered.history!.id);
		provider.acknowledgeHistory(offered.history!.id);
		provider.beginHistoryFlush();
		drain(provider, history);
		expect(content(history)).toEqual(["banner", "first", "second", "third", "fourth"]);
		const renders = first.renders;
		for (let i = 0; i < 5; i++) expect(provider.renderFrame(SIZE).history).toBeUndefined();
		expect(first.renders).toBe(renders);
		expect(provider.renderFrame(SIZE).viewport).toEqual(["editor"]);
	});

	test("an active frontier blocks later history but remains visible under pressure", () => {
		const transcript = new TranscriptContainer();
		const active = new Rows(["active one", "active two", "active three", "active four"]);
		active.finalized = false;
		transcript.addChild(active);
		transcript.addChild(new Rows(["later notice"]));
		const provider = new RowFrameProvider(transcript, [], [new Rows(["editor"])]);
		const plan = provider.renderFrame({ columns: 80, rows: 4 });
		expect(plan.history).toBeUndefined();
		expect(content(plan.viewport)).toContain("active four");
		expect(content(plan.viewport)).toContain("later notice");
		active.finalized = true;
		provider.beginHistoryFlush();
		const history: string[] = [];
		drain(provider, history);
		expect(content(history)).toEqual([...active.rows, "later notice"]);
	});

	test("long streaming replies retire stable heads and interrupted tails exactly once", () => {
		const transcript = new TranscriptContainer();
		const assistant = new AssistantMessageComponent();
		transcript.addChild(assistant);
		const provider = new RowFrameProvider(transcript, [], [new Rows(["editor"])]);
		const history: string[] = [];
		let text = "";
		for (let i = 0; i < 20; i++) {
			text += `${i > 0 ? "\n\n" : ""}paragraph-${i}`;
			assistant.updateContent(text);
			const plan = drain(provider, history);
			expect(renderPlain(plan.viewport)).toContain(`paragraph-${i}`);
		}
		expect(content(history)).toContain(" paragraph-0");
		expect(transcript.emittedStableRows()[0]).toBeGreaterThan(0);
		assistant.finalize({ interrupted: true });
		const expected = content(assistant.render(SIZE.columns));
		provider.beginHistoryFlush();
		drain(provider, history);
		expect(content(history)).toEqual(expected);
		expect(content(history).filter((row) => row.includes("[interrupted]"))).toHaveLength(1);
	});

	test("temporary dock growth clips without committing displaced transcript rows", () => {
		const transcript = new TranscriptContainer();
		transcript.addChild(new Rows(["one", "two", "three", "four"]));
		const dock = new Rows(["editor"]);
		const provider = new RowFrameProvider(transcript, [], [dock]);
		const before = provider.renderFrame(SIZE);
		expect(before.history).toBeUndefined();
		dock.rows = ["approval one", "approval two", "approval three", "editor"];
		const covered = provider.renderFrame(SIZE);
		expect(covered.history).toBeUndefined();
		expect(covered.viewport.length).toBeLessThanOrEqual(SIZE.rows);
		dock.rows = ["editor"];
		expect(provider.renderFrame(SIZE)).toEqual(before);
	});

	test("an animating header stays live under pressure and retires its settled frame", () => {
		const transcript = new TranscriptContainer();
		transcript.addChild(new Rows(["one", "two", "three", "four", "five", "six"]));
		const banner = new Rows(["banner frame 1"]);
		banner.finalized = false;
		const header = new Container();
		header.addChild(banner);
		const provider = new RowFrameProvider(transcript, [header], [new Rows(["editor"])]);
		const plan = provider.renderFrame(SIZE);
		expect(plan.history).toBeUndefined();
		expect(plan.viewport.length).toBeLessThanOrEqual(SIZE.rows);
		banner.rows = ["banner settled"];
		banner.finalized = true;
		const history: string[] = [];
		drain(provider, history);
		expect(content(history)[0]).toBe("banner settled");
		expect(content(history)).not.toContain("banner frame 1");
	});

	test("resize previews do not retire, and replay preserves the emitted source boundary", () => {
		const transcript = new TranscriptContainer();
		const assistant = new AssistantMessageComponent();
		transcript.addChild(assistant);
		const provider = new RowFrameProvider(transcript, [], [new Rows(["editor"])]);
		let text = "";
		const history: string[] = [];
		for (let i = 0; i < 12; i++) {
			text += `${i ? "\n\n" : ""}source-${i} with some words to reflow`;
			assistant.updateContent(text);
			drain(provider, history);
		}
		const emitted = transcript.emittedStableRows();
		for (const columns of [24, 40, 12, 80]) {
			const preview = provider.renderResizeFrame({ columns, rows: 8 });
			expect(preview.length).toBeLessThanOrEqual(8);
			expect(preview.every((row) => visibleWidth(row) <= columns)).toBe(true);
			expect(transcript.emittedStableRows()).toEqual(emitted);
		}
		provider.beginHistoryReplay();
		const replay = provider.renderFrame({ columns: 40, rows: 20 });
		expect(replay.history?.kind).toBe("replay");
		expect(transcript.emittedStableRows()).toEqual(emitted);
		const replayed = content([...(replay.history?.rows ?? []), ...replay.viewport]).join("\n");
		for (let i = 0; i < 12; i++) {
			expect(replayed.match(new RegExp(`source-${i}(?![0-9])`, "g"))).toHaveLength(1);
		}
		provider.acknowledgeHistory(replay.history!.id);
		expect(provider.renderFrame({ columns: 40, rows: 20 }).history).toBeUndefined();
	});

	test("reset discards stale offers without reusing terminal history ids", () => {
		const transcript = new TranscriptContainer();
		transcript.addChild(new Rows(["old session"]));
		const provider = new RowFrameProvider(transcript, [], []);
		provider.beginHistoryFlush();
		const old = provider.renderFrame(SIZE).history!;
		transcript.disposeChildren();
		transcript.addChild(new Rows(["new session"]));
		provider.beginHistoryReplay();
		provider.acknowledgeHistory(old.id);
		provider.beginHistoryFlush();
		const current = provider.renderFrame(SIZE).history!;
		expect(current.id).toBeGreaterThan(old.id);
		expect(content(current.rows)).toEqual(["new session"]);
		provider.acknowledgeHistory(current.id);
		expect(provider.renderFrame(SIZE).history).toBeUndefined();
	});

	test("replay requested during an offer waits for acknowledgement and stop cancels unoffered replay", () => {
		const transcript = new TranscriptContainer();
		transcript.addChild(new Rows(["one", "two", "three", "four", "five", "six", "seven"]));
		const provider = new RowFrameProvider(transcript, [], []);
		const offered = provider.renderFrame(SIZE).history!;
		provider.beginHistoryReplay();
		expect(provider.renderFrame(SIZE).history).toBe(offered);
		provider.acknowledgeHistory(offered.id);
		const replay = provider.renderFrame(SIZE).history!;
		expect(replay.kind).toBe("replay");
		provider.acknowledgeHistory(replay.id);
		provider.beginHistoryReplay();
		provider.beginHistoryFlush();
		const rest: string[] = [];
		drain(provider, rest);
		expect(content([...offered.rows, ...rest])).toEqual([
			"one",
			"two",
			"three",
			"four",
			"five",
			"six",
			"seven",
		]);
	});

	test("native main retains retired component identities and dock stays separate", () => {
		const transcript = new TranscriptContainer();
		const message = new Rows(["answer"]);
		const header = new Rows(["banner"]);
		const editor = new Rows(["editor"]);
		transcript.addChild(message);
		const provider = new RowFrameProvider(transcript, [header], [editor]);
		const cx = {
			cols: 80,
			dark: true,
			reduceMotion: true,
			supports: () => true,
			feature: () => false,
		};
		const surface = provider.describeSurface(cx);
		expect(surface.main).toEqual([header, message]);
		expect(surface.dock).toEqual([editor]);
		provider.beginHistoryFlush();
		drain(provider, []);
		expect(provider.describeSurface(cx)).toBe(surface);
		const next = new Rows(["next"]);
		transcript.addChild(next);
		expect(provider.describeSurface(cx).main).toEqual([header, message, next]);
	});

	test("the real writer keeps overlay rows out of history and flushes once on stop", async () => {
		const terminal = new MemoryTerminal();
		terminal.rows = 6;
		const paints: Array<{ history: readonly string[]; alt: boolean }> = [];
		const tui = new TUI(terminal, false, { onPaint: (paint) => paints.push(paint) });
		const transcript = new TranscriptContainer();
		transcript.addChild(new Rows(["before overlay"]));
		const dock = new Rows(["editor"]);
		tui.addChild(transcript);
		tui.addChild(dock);
		tui.setFrameProvider(new RowFrameProvider(transcript, [], [dock], tui));
		tui.start();
		try {
			await waitFor(() => paints.length > 0, { what: "the initial row frame" });
			const overlay = tui.showOverlay(new Rows(["modal content"]), { width: "100%", minWidth: 1 });
			transcript.addChild(
				new Rows(["after overlay", "tail one", "tail two", "tail three", "tail four"]),
			);
			tui.requestRender();
			await waitFor(() => terminal.writes.some((write) => write.includes("modal content")), {
				what: "the overlay",
			});
			overlay.hide();
			tui.requestRender();
		} finally {
			tui.stop();
		}
		const history = paints.flatMap((paint) => paint.history);
		expect(content(history)).toEqual([
			"before overlay",
			"after overlay",
			"tail one",
			"tail two",
			"tail three",
			"tail four",
		]);
		expect(renderPlain(history)).not.toContain("modal content");
		expect(renderPlain(history)).not.toContain("editor");
	});
});
