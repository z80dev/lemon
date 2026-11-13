/**
 * Composer options the editor forwards to pi-tui: Vim mode and the composite
 * autocomplete provider's inline emoji replacement.
 */

import { afterEach, beforeEach, expect, test } from "bun:test";
import { CustomEditor } from "../../src/ui/components/custom-editor.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { getEditorTheme, invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";

beforeEach(() => {
	initTheme({ colorLevel: 3 });
});

afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

function makeEditor(vimMode?: boolean): CustomEditor {
	return new CustomEditor({ theme: getEditorTheme(), onSubmit: () => {}, vimMode });
}

test("vimMode starts the composer in modal editing, insert mode first", () => {
	const editor = makeEditor(true);
	expect(editor.vimEnabled).toBe(true);
	expect(editor.vimMode).toBe("insert");
});

test("the composer is not modal unless vim_mode is set", () => {
	expect(makeEditor().vimEnabled).toBe(false);
	expect(makeEditor(false).vimEnabled).toBe(false);
});

test("typing :joy: becomes the emoji once commands install the composer provider", () => {
	const editor = makeEditor();
	editor.setCommands([{ name: "help" }]);
	for (const char of "ok :joy:") editor.handleInput(char);
	expect(editor.getText()).toBe("ok 😂");
});
