import { describe, expect, test } from "bun:test";
import { readFile, writeFile } from "node:fs/promises";
import {
	editInExternalEditor,
	resolveEditorCommand,
	splitEditorCommand,
} from "../src/external-editor.ts";

describe("resolveEditorCommand", () => {
	test("prefers the lemon override, then VISUAL, then EDITOR", () => {
		expect(resolveEditorCommand({ LEMON_EDITOR: "a", VISUAL: "b", EDITOR: "c" })).toBe("a");
		expect(resolveEditorCommand({ VISUAL: "b", EDITOR: "c" })).toBe("b");
		expect(resolveEditorCommand({ EDITOR: "c" })).toBe("c");
		expect(resolveEditorCommand({})).toBeUndefined();
		expect(resolveEditorCommand({ EDITOR: "   " })).toBeUndefined();
	});

	test("keeps flags in the command", () => {
		expect(splitEditorCommand("code  -w")).toEqual(["code", "-w"]);
	});
});

describe("editInExternalEditor", () => {
	test("seeds the file with the draft and returns what was written", async () => {
		let seen = "";
		const result = await editInExternalEditor("draft text", {
			command: "fake-editor",
			spawn: async (_argv, file) => {
				seen = await readFile(file, "utf-8");
				await writeFile(file, "edited text\n");
				return 0;
			},
		});
		expect(seen).toBe("draft text");
		expect(result).toBe("edited text");
	});

	test("an unchanged file leaves the draft alone", async () => {
		const result = await editInExternalEditor("draft", {
			command: "fake-editor",
			spawn: async () => 0,
		});
		expect(result).toBeNull();
	});

	test("a non-zero exit is an abort, not an edit", async () => {
		const result = await editInExternalEditor("draft", {
			command: "fake-editor",
			spawn: async (_argv, file) => {
				await writeFile(file, "changed but aborted");
				return 1;
			},
		});
		expect(result).toBeNull();
	});

	test("the terminal is restored even when the editor throws", async () => {
		const events: string[] = [];
		const tui = {
			stop: () => events.push("stop"),
			start: () => events.push("start"),
		};
		await expect(
			editInExternalEditor("draft", {
				command: "fake-editor",
				tui,
				spawn: async () => {
					throw new Error("spawn failed");
				},
			}),
		).rejects.toThrow("spawn failed");
		expect(events).toEqual(["stop", "start"]);
	});

	test("suspends and restores around a normal edit", async () => {
		const events: string[] = [];
		await editInExternalEditor("draft", {
			command: "fake-editor",
			tui: { stop: () => events.push("stop"), start: () => events.push("start") },
			spawn: async () => 0,
		});
		expect(events).toEqual(["stop", "start"]);
	});

	test("refuses when no editor is configured", async () => {
		await expect(editInExternalEditor("draft", { env: {} })).rejects.toThrow(/no editor/);
	});

	test("the temp file is cleaned up", async () => {
		let path = "";
		await editInExternalEditor("draft", {
			command: "fake-editor",
			spawn: async (_argv, file) => {
				path = file;
				await writeFile(file, "new");
				return 0;
			},
		});
		expect(await Bun.file(path).exists()).toBe(false);
	});
});
