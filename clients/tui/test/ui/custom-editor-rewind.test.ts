/** Idle Esc Esc on an empty composer opens the rewind picker; a draft keeps discard. */

import { afterEach, beforeEach, expect, test } from "bun:test";
import { CustomEditor, ESC_DISCARD_MS } from "../../src/ui/components/custom-editor.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { getEditorTheme, invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";

const ESC = "\x1b";

let now: number;
let running: boolean;
let rewinds: number;
let editor: CustomEditor;

beforeEach(() => {
	initTheme({ colorLevel: 3 });
	now = 1_000_000;
	running = false;
	rewinds = 0;
	editor = new CustomEditor({
		theme: getEditorTheme(),
		onSubmit: () => {},
		onAbort: () => running,
		onRewind: () => {
			rewinds += 1;
		},
		now: () => now,
	});
});

afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

test("a double Escape on an empty draft opens the rewind picker once", () => {
	editor.handleInput(ESC);
	expect(rewinds).toBe(0);
	editor.handleInput(ESC);
	expect(rewinds).toBe(1);
	// The pair is consumed: a third Escape starts a new one.
	editor.handleInput(ESC);
	expect(rewinds).toBe(1);
});

test("a slow second Escape does not open the picker", () => {
	editor.handleInput(ESC);
	now += ESC_DISCARD_MS + 1;
	editor.handleInput(ESC);
	expect(rewinds).toBe(0);
});

test("a non-empty draft is discarded instead of opening the picker", () => {
	editor.handleInput("draft");
	editor.handleInput(ESC);
	editor.handleInput(ESC);
	expect(editor.getText()).toBe("");
	expect(rewinds).toBe(0);
});

test("Escape during a live run aborts it and never opens the picker", () => {
	running = true;
	editor.handleInput(ESC);
	editor.handleInput(ESC);
	expect(rewinds).toBe(0);
});
