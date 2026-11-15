import { afterEach, expect, test } from "bun:test";
import { CustomEditor } from "../../src/ui/components/custom-editor.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { getEditorTheme, invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";

afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

test("compose hint fires on first edit, not navigation or every character, and rearms for next prompt", () => {
	initTheme({ colorLevel: 3 });
	let hints = 0;
	const editor = new CustomEditor({
		theme: getEditorTheme(),
		onSubmit: () => {},
		onComposeStart: () => { hints += 1; },
	});
	editor.handleInput("\x1b[D");
	expect(hints).toBe(0);
	editor.handleInput("h");
	editor.handleInput("i");
	expect(hints).toBe(1);
	editor.handleInput("\r");
	editor.handleInput("n");
	expect(hints).toBe(2);
});

test("native edits and paste share the first-compose hint, but caret and stale edits do not", async () => {
	initTheme({ colorLevel: 3 });
	let hints = 0;
	const editor = new CustomEditor({
		theme: getEditorTheme(),
		onSubmit: () => {},
		onComposeStart: () => { hints += 1; },
	});
	editor.handleNativeEvent({ type: "edit", key: "line/input", from: 0, to: 0, text: "", cursor: 0, len: 0 });
	expect(hints).toBe(0);
	editor.handleNativeEvent({ type: "edit", key: "line/input", from: 0, to: 0, text: "a", cursor: 1, len: 0 });
	expect(hints).toBe(1);
	editor.handleNativeEvent({ type: "edit", key: "line/input", from: 1, to: 1, text: "b", cursor: 2, len: 1 });
	expect(hints).toBe(1);
	editor.setText("");
	editor.handleNativeEvent({ type: "edit", key: "line/input", from: 0, to: 0, text: "stale", cursor: 5, len: 9 });
	expect(hints).toBe(1);
	await editor.pasteContent("pasted");
	expect(hints).toBe(2);
	await editor.pasteContent(" more");
	expect(hints).toBe(2);
	editor.setText("");
	editor.handleInput("\x1b[200~bracketed paste\x1b[201~");
	expect(hints).toBe(3);
});
