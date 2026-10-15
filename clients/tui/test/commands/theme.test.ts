import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

let home: string;
let previousHome: string | undefined;
let harness: Harness;
beforeEach(async () => {
	previousHome = process.env.HOME;
	home = mkdtempSync(join(tmpdir(), "lemon-theme-notices-"));
	process.env.HOME = home;
	initTheme({ colorLevel: 3 });
	harness = await createHarness();
});
afterEach(() => {
	harness.stop();
	resetTheme();
	invalidateThemeAdapters();
	if (previousHome === undefined) delete process.env.HOME;
	else process.env.HOME = previousHome;
	rmSync(home, { recursive: true, force: true });
});

test("theme success says it was saved only after writing the configuration", async () => {
	await harness.run("/theme light");
	expect(harness.host.last?.text).toBe("theme: lemon-light (saved)");
	expect(readFileSync(join(home, ".lemon/config.toml"), "utf8")).toContain('theme = "light"');
});

test("a refused config write labels the theme session-only", async () => {
	mkdirSync(join(home, ".lemon"));
	writeFileSync(join(home, ".lemon/config.toml"), "not valid TOML = [");
	await harness.run("/theme dark");
	expect(harness.host.last?.level).toBe("warning");
	expect(harness.host.last?.text).toContain("session only — could not save");
	expect(harness.host.text).not.toContain("(saved)");
});
