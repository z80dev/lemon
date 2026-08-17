/**
 * Gallery smoke: it must run headless, cover every fixture, and never emit a
 * row wider than the width it was asked for — the same width discipline the
 * transcript enforces, checked here across every renderer at once.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import { fixturePhases, TOOL_FIXTURES } from "../../src/dev/fixtures/tool-fixtures.ts";
import { parseGalleryArgs, renderGallery, runGallery } from "../../src/dev/gallery.ts";
import { resetBlockIds } from "../../src/store/transcript-model.ts";
import { resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { renderPlain } from "../helpers/memory-terminal.ts";

beforeEach(() => {
	resetBlockIds();
});

afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

describe("argument parsing", () => {
	test("defaults to every state and section at 80 and 120 columns", () => {
		const options = parseGalleryArgs([]);
		expect(options.widths).toEqual([80, 120]);
		expect(options.states).toEqual(["streaming", "running", "success", "error"]);
		expect(options.sections).toEqual(["tools", "diff", "shelf", "accordion"]);
	});

	test("accepts repeated and comma-separated values", () => {
		const options = parseGalleryArgs(["--width", "60,100", "--state", "error", "--tool", "edit"]);
		expect(options.widths).toEqual([60, 100]);
		expect(options.states).toEqual(["error"]);
		expect(options.tool).toBe("edit");
	});

	test("rejects nonsense rather than rendering something misleading", () => {
		expect(() => parseGalleryArgs(["--state", "sideways"])).toThrow(/unknown --state/);
		expect(() => parseGalleryArgs(["--width", "3"])).toThrow(/invalid --width/);
		expect(() => parseGalleryArgs(["--section", "nope"])).toThrow(/unknown --section/);
		expect(() => parseGalleryArgs(["--wat"])).toThrow(/unknown flag/);
	});
});

describe("rendering", () => {
	test("runs headless and produces output", () => {
		const lines = runGallery(["--width", "80"]);
		expect(lines.length).toBeGreaterThan(50);
		expect(lines.join("\n").trim().length).toBeGreaterThan(0);
	});

	test("no line exceeds the requested width, at any width", () => {
		for (const width of [40, 80, 120]) {
			for (const line of runGallery(["--width", String(width)])) {
				expect(visibleWidth(line)).toBeLessThanOrEqual(width);
			}
		}
	});

	test("covers every fixture by name", () => {
		const text = renderPlain(runGallery(["--width", "120", "--section", "tools"]));
		for (const fixture of TOOL_FIXTURES) {
			expect(text).toContain(fixture.name);
		}
	});

	test("--tool narrows to one fixture and --state to one state", () => {
		const text = renderPlain(runGallery(["--tool", "edit", "--state", "success", "--width", "80"]));
		expect(text).toContain("edit ");
		expect(text).toContain("success");
		expect(text).not.toContain("streaming args");
		expect(text).not.toContain("grep: upsertTool");
	});

	test("--tool with no such fixture fails loudly", () => {
		expect(() => runGallery(["--tool", "nonexistent"])).toThrow(/no fixture/);
	});

	test("--plain strips every escape sequence", () => {
		const text = runGallery(["--width", "80", "--plain"]).join("\n");
		expect(text).not.toContain("\x1b");
	});

	test("--list names the fixtures and flags without rendering any", () => {
		const text = runGallery(["--list"]).join("\n");
		expect(text).toContain("bash");
		expect(text).toContain("--section");
		expect(text).not.toContain("drwxr-xr-x");
	});

	test("is deterministic — two runs are byte-identical", () => {
		const first = runGallery(["--width", "80", "--plain"]).join("\n");
		const second = runGallery(["--width", "80", "--plain"]).join("\n");
		expect(second).toBe(first);
	});

	test("each section renders on its own", () => {
		for (const section of ["tools", "diff", "shelf", "accordion"]) {
			const lines = renderGallery({
				widths: [80],
				states: ["success"],
				sections: [section as "tools"],
				tool: undefined,
				plain: true,
				list: false,
			});
			expect(lines.length).toBeGreaterThan(2);
		}
	});
});

describe("fixtures", () => {
	test("every fixture reaches each lifecycle state through real phases", () => {
		for (const fixture of TOOL_FIXTURES) {
			expect(fixturePhases(fixture, "streaming").length).toBe(1);
			expect(fixturePhases(fixture, "success").at(-1)?.phase).toBe("completed");
			expect(fixturePhases(fixture, "error").at(-1)?.ok).toBe(false);
			// A `running` fixture must never already be completed.
			for (const step of fixturePhases(fixture, "running")) {
				expect(step.phase).not.toBe("completed");
			}
		}
	});
});
