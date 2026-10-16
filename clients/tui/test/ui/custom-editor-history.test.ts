/**
 * ↑ recall across sessions persists submitted prompts only. Discarded drafts
 * stay in the local ring, and clearing forgets both local and saved history.
 */

import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PromptHistoryStore } from "../../src/composer/prompt-history.ts";
import { CustomEditor, HISTORY_LIMIT } from "../../src/ui/components/custom-editor.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { getEditorTheme, invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";

const CTRL_C = "\x03";
const ESC = "\x1b";
const UP = "\x1b[A";
const DOWN = "\x1b[B";
const ENTER = "\r";

let dir: string;
let file: string;

beforeEach(() => {
	initTheme({ colorLevel: 3 });
	dir = mkdtempSync(join(tmpdir(), "lemon-editor-history-"));
	file = join(dir, "tui-history", "history.sqlite3");
});

afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
	rmSync(dir, { recursive: true, force: true });
});

function makeEditor(promptHistory?: PromptHistoryStore, notices: string[] = []): CustomEditor {
	return new CustomEditor({
		theme: getEditorTheme(),
		onSubmit: () => {},
		notice: (text) => notices.push(text),
		promptHistory,
	});
}

test("submitted prompts are saved privately and recalled by the next editor", () => {
	const first = makeEditor(new PromptHistoryStore(file));
	first.handleInput("remember me");
	first.handleInput(ENTER);
	first.handleInput("and me");
	first.handleInput(ENTER);
	expect(statSync(file).mode & 0o777).toBe(0o600);

	const second = makeEditor(new PromptHistoryStore(file));
	expect(second.history).toEqual(["remember me", "and me"]);
	second.handleInput(UP);
	expect(second.getText()).toBe("and me");
	second.handleInput(UP);
	expect(second.getText()).toBe("remember me");
});

test.each([
	["Ctrl+C", [CTRL_C]],
	["double Escape", [ESC, ESC]],
] as const)("typing, recall and %s discard never append to disk", (_name, discard) => {
	const store = new PromptHistoryStore(file);
	store.append("already submitted");
	const append = spyOn(store, "append");
	try {
		const editor = makeEditor(store);
		editor.handleInput(UP);
		expect(editor.getText()).toBe("already submitted");
		editor.handleInput(DOWN);
		editor.handleInput("half-typed");
		expect(append).not.toHaveBeenCalled();
		for (const key of discard) editor.handleInput(key);
		expect(editor.getText()).toBe("");
		expect(editor.history).toEqual(["already submitted", "half-typed"]);
		editor.handleInput(UP);
		expect(editor.getText()).toBe("half-typed");
		expect(append).not.toHaveBeenCalled();
		expect(makeEditor(new PromptHistoryStore(file)).history).toEqual(["already submitted"]);

		// A recalled discarded draft becomes durable only when submitted.
		editor.handleInput(ENTER);
		expect(append).toHaveBeenCalledTimes(1);
		expect(append).toHaveBeenCalledWith("half-typed");
		expect(new PromptHistoryStore(file).load()).toEqual(["already submitted", "half-typed"]);
	} finally {
		append.mockRestore();
	}
});

test("delegation preserves the human draft only in memory and saves the delegated submission", () => {
	const store = new PromptHistoryStore(file);
	const editor = makeEditor(store);
	editor.handleInput("unfinished human draft");
	editor.handleNativeEvent({ type: "send", key: "", text: "delegated prompt" });
	expect(editor.history).toEqual(["unfinished human draft", "delegated prompt"]);
	expect(new PromptHistoryStore(file).load()).toEqual(["delegated prompt"]);
	editor.handleInput(UP);
	editor.handleInput(UP);
	expect(editor.getText()).toBe("unfinished human draft");
});

test("only the newest HISTORY_LIMIT saved prompts are loaded", () => {
	const store = new PromptHistoryStore(file, { maxEntries: HISTORY_LIMIT + 20 });
	for (let i = 0; i < HISTORY_LIMIT + 20; i++) store.append(`prompt ${i}`);
	const editor = makeEditor(store);
	expect(editor.history).toHaveLength(HISTORY_LIMIT);
	expect(editor.history.at(-1)).toBe(`prompt ${HISTORY_LIMIT + 19}`);
});

test("resubmitting a locally remembered prompt after another client clears saves it again", () => {
	const store = new PromptHistoryStore(file);
	const editor = makeEditor(store);
	editor.handleInput("submit again");
	editor.handleInput(ENTER);
	new PromptHistoryStore(file).clear();
	editor.handleInput(UP);
	editor.handleInput(ENTER);
	expect(new PromptHistoryStore(file).load()).toEqual(["submit again"]);
	expect(editor.history).toEqual(["submit again"]);
});

test("clearHistory forgets both rings and empties the database in place", () => {
	const store = new PromptHistoryStore(file);
	const editor = makeEditor(store);
	editor.handleInput("secret token");
	editor.handleInput(ENTER);
	expect(existsSync(file)).toBe(true);

	editor.clearHistory();
	expect(editor.history).toEqual([]);
	expect(existsSync(file)).toBe(true);
	expect(store.load()).toEqual([]);
	editor.handleInput(UP);
	expect(editor.getText()).toBe("");
	expect(makeEditor(new PromptHistoryStore(file)).history).toEqual([]);
});

test.each(["/clear-history", "/CLEAR-HISTORY"])("%s never appends itself", (command) => {
	const store = new PromptHistoryStore(file);
	store.append("secret token");
	const append = spyOn(store, "append");
	try {
		const editor: CustomEditor = new CustomEditor({
			theme: getEditorTheme(),
			promptHistory: store,
			onSubmit: () => editor.clearHistory(),
		});
		editor.handleInput(command);
		editor.handleInput(ENTER);
		expect(append).not.toHaveBeenCalled();
		expect(editor.history).toEqual([]);
		expect(new PromptHistoryStore(file).load()).toEqual([]);
	} finally {
		append.mockRestore();
	}
});

test("without a store nothing is written and clearHistory still empties the ring", () => {
	const editor = makeEditor();
	editor.handleInput("in memory only");
	editor.handleInput(ENTER);
	expect(editor.history).toEqual(["in memory only"]);
	editor.clearHistory();
	expect(editor.history).toEqual([]);
	expect(existsSync(file)).toBe(false);
});

test("load permission failures warn without crashing construction or disabling recall", async () => {
	const store = new PromptHistoryStore(file);
	const load = spyOn(store, "load").mockImplementation(() => {
		throw new Error("EACCES: permission denied opening prompt history");
	});
	const notices: Array<{ text: string; level: string | undefined }> = [];
	try {
		const editor = new CustomEditor({
			theme: getEditorTheme(),
			promptHistory: store,
			onSubmit: () => {},
			notice: (text, level) => notices.push({ text, level }),
		});
		expect(editor.history).toEqual([]);
		await Promise.resolve();
		expect(notices).toEqual([
			{
				text: "prompt history could not be loaded (EACCES: permission denied opening prompt history); ↑ recall still works this session",
				level: "warning",
			},
		]);
		editor.handleInput("still usable");
		editor.handleInput(CTRL_C);
		editor.handleInput(UP);
		expect(editor.getText()).toBe("still usable");
	} finally {
		load.mockRestore();
	}
});

test("a failed save warns once and recall keeps working", () => {
	const store = new PromptHistoryStore(file);
	const append = spyOn(store, "append").mockImplementation(() => {
		throw new Error("EACCES: permission denied saving prompt history");
	});
	const notices: string[] = [];
	try {
		const editor = makeEditor(store, notices);
		for (const prompt of ["one", "two"]) {
			editor.handleInput(prompt);
			editor.handleInput(ENTER);
		}
		expect(notices.filter((n) => n.startsWith("prompt history was not saved"))).toHaveLength(1);
		expect(editor.history).toEqual(["one", "two"]);
		expect(new PromptHistoryStore(file).load()).toEqual([]);
	} finally {
		append.mockRestore();
	}
});

test("a failed persistent clear still empties the local recall ring", () => {
	const store = new PromptHistoryStore(file);
	const editor = makeEditor(store);
	editor.handleInput("secret token");
	editor.handleInput(ENTER);
	const clear = spyOn(store, "clear").mockImplementation(() => {
		throw new Error("database is locked");
	});
	try {
		expect(() => editor.clearHistory()).toThrow("database is locked");
		expect(editor.history).toEqual([]);
		editor.handleInput(UP);
		expect(editor.getText()).toBe("");
	} finally {
		clear.mockRestore();
	}
});
