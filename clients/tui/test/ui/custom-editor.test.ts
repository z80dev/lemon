/**
 * The editor's key policy, driven the way the terminal drives it: raw bytes
 * into `handleInput`.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import {
	CustomEditor,
	ESC_DISCARD_MS,
	EXIT_CONFIRM_MS,
} from "../../src/ui/components/custom-editor.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { getEditorTheme, invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";

const CTRL_C = "\x03";
const CTRL_D = "\x04";
const CTRL_G = "\x07";
const ESC = "\x1b";
const UP = "\x1b[A";
const DOWN = "\x1b[B";
const ENTER = "\r";

interface Recorded {
	editor: CustomEditor;
	submitted: string[];
	notices: string[];
	quits: number[];
	aborts: number;
	edits: number;
	setNow: (value: number) => void;
	setRunning: (running: boolean) => void;
}

function makeEditor(): Recorded {
	const submitted: string[] = [];
	const notices: string[] = [];
	const quits: number[] = [];
	let aborts = 0;
	let edits = 0;
	let now = 1_000_000;
	let running = false;

	const editor = new CustomEditor({
		theme: getEditorTheme(),
		onSubmit: (text) => {
			submitted.push(text);
		},
		onAbort: () => {
			if (!running) return false;
			aborts += 1;
			return true;
		},
		onQuit: (code) => quits.push(code),
		onExternalEdit: () => {
			edits += 1;
		},
		notice: (text) => notices.push(text),
		now: () => now,
	});

	return {
		editor,
		submitted,
		notices,
		quits,
		get aborts() {
			return aborts;
		},
		get edits() {
			return edits;
		},
		setNow: (value: number) => {
			now = value;
		},
		setRunning: (value: boolean) => {
			running = value;
		},
	} as Recorded;
}

beforeEach(() => {
	initTheme({ colorLevel: 3 });
});

afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

describe("typing and submitting", () => {
	test("plain text reaches the buffer and Enter submits it", () => {
		const h = makeEditor();
		h.editor.handleInput("hi");
		expect(h.editor.getText()).toBe("hi");
		h.editor.handleInput(ENTER);
		expect(h.submitted).toEqual(["hi"]);
		expect(h.editor.getText()).toBe("");
	});

	test("an empty submission is dropped", () => {
		const h = makeEditor();
		h.editor.handleInput(ENTER);
		expect(h.submitted).toEqual([]);
	});

	test("submitted prompts join the recall ring", () => {
		const h = makeEditor();
		h.editor.handleInput("first");
		h.editor.handleInput(ENTER);
		expect(h.editor.history).toEqual(["first"]);
	});
});

describe("Ctrl+C", () => {
	test("clears a non-empty draft without quitting", () => {
		const h = makeEditor();
		h.editor.handleInput("half a thought");
		h.editor.handleInput(CTRL_C);
		expect(h.editor.getText()).toBe("");
		expect(h.quits).toEqual([]);
		// The cleared draft is recoverable.
		expect(h.editor.history).toEqual(["half a thought"]);
	});

	test("aborts a live run when the draft is empty", () => {
		const h = makeEditor();
		h.setRunning(true);
		h.editor.handleInput(CTRL_C);
		expect(h.aborts).toBe(1);
		expect(h.quits).toEqual([]);
	});

	test("twice in a row quits when nothing is running", () => {
		const h = makeEditor();
		h.editor.handleInput(CTRL_C);
		expect(h.notices).toContain("press Ctrl+C again to quit");
		expect(h.quits).toEqual([]);
		h.editor.handleInput(CTRL_C);
		expect(h.quits).toEqual([0]);
	});

	test("the confirm window expires", () => {
		const h = makeEditor();
		h.editor.handleInput(CTRL_C);
		h.setNow(1_000_000 + EXIT_CONFIRM_MS + 1);
		h.editor.handleInput(CTRL_C);
		expect(h.quits).toEqual([]);
		expect(h.notices).toHaveLength(2);
	});

	test("an abort disarms the quit confirmation", () => {
		const h = makeEditor();
		h.editor.handleInput(CTRL_C);
		h.setRunning(true);
		h.editor.handleInput(CTRL_C);
		h.setRunning(false);
		h.editor.handleInput(CTRL_C);
		expect(h.quits).toEqual([]);
	});
});

describe("Ctrl+D and Ctrl+G", () => {
	test("Ctrl+D quits on an empty draft", () => {
		const h = makeEditor();
		h.editor.handleInput(CTRL_D);
		expect(h.quits).toEqual([0]);
	});

	test("Ctrl+D deletes forward when there is text", () => {
		const h = makeEditor();
		h.editor.handleInput("abc");
		h.editor.moveToLineStart();
		h.editor.handleInput(CTRL_D);
		expect(h.quits).toEqual([]);
		expect(h.editor.getText()).toBe("bc");
	});

	test("Ctrl+G hands off to the external editor", () => {
		const h = makeEditor();
		h.editor.handleInput(CTRL_G);
		expect(h.edits).toBe(1);
	});
});

describe("Esc Esc", () => {
	test("a double press discards the draft, recoverable with up", () => {
		const h = makeEditor();
		h.editor.handleInput("draft text");
		h.editor.handleInput(ESC);
		expect(h.editor.getText()).toBe("draft text");
		h.editor.handleInput(ESC);
		expect(h.editor.getText()).toBe("");
		h.editor.handleInput(UP);
		expect(h.editor.getText()).toBe("draft text");
	});

	test("a slow second press does not discard", () => {
		const h = makeEditor();
		h.editor.handleInput("draft text");
		h.editor.handleInput(ESC);
		h.setNow(1_000_000 + ESC_DISCARD_MS + 1);
		h.editor.handleInput(ESC);
		expect(h.editor.getText()).toBe("draft text");
	});
});

describe("history recall", () => {
	test("up walks back through sent prompts and down returns", () => {
		const h = makeEditor();
		for (const text of ["one", "two"]) {
			h.editor.handleInput(text);
			h.editor.handleInput(ENTER);
		}
		h.editor.handleInput(UP);
		expect(h.editor.getText()).toBe("two");
		h.editor.handleInput(UP);
		expect(h.editor.getText()).toBe("one");
		h.editor.handleInput(DOWN);
		expect(h.editor.getText()).toBe("two");
		h.editor.handleInput(DOWN);
		expect(h.editor.getText()).toBe("");
	});

	test("up with a non-empty draft moves the cursor instead of recalling", () => {
		const h = makeEditor();
		h.editor.handleInput("sent");
		h.editor.handleInput(ENTER);
		h.editor.handleInput("in progress");
		h.editor.handleInput(UP);
		expect(h.editor.getText()).toBe("in progress");
	});

	test("recall does nothing with an empty ring", () => {
		const h = makeEditor();
		h.editor.handleInput(UP);
		expect(h.editor.getText()).toBe("");
	});
});

describe("rendering", () => {
	test("no rendered row is wider than the terminal", () => {
		const h = makeEditor();
		h.editor.handleInput("a prompt long enough that it has to wrap at narrow widths, 日本語 too");
		for (const width of [40, 60, 80, 120]) {
			for (const line of h.editor.render(width)) {
				expect(Bun.stringWidth(line)).toBeLessThanOrEqual(width);
			}
		}
	});
});
