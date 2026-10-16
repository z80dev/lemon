import { afterEach, beforeEach, expect, test } from "bun:test";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

let harness: Harness;
beforeEach(async () => {
	initTheme({ colorLevel: 3 });
	harness = await createHarness();
});
afterEach(() => {
	harness.stop();
	resetTheme();
	invalidateThemeAdapters();
});

test("/clear-history clears through the host and confirms", async () => {
	let cleared = 0;
	harness.host.clearPromptHistory = () => {
		cleared += 1;
	};
	await harness.run("/clear-history");
	expect(cleared).toBe(1);
	expect(harness.host.last).toEqual({ text: "prompt history cleared", level: "info" });
});

test("/clear-history reports persistent storage failures without claiming success", async () => {
	harness.host.clearPromptHistory = () => {
		throw new Error("EACCES: permission denied");
	};
	await harness.run("/clear-history");
	expect(harness.host.last?.level).toBe("error");
	expect(harness.host.last?.text).toBe(
		"prompt history cleared in memory, but persistent history could not be cleared: EACCES: permission denied",
	);
});

test("/clear-history says so when the host keeps no prompt history", async () => {
	await harness.run("/clear-history");
	expect(harness.host.last?.level).toBe("warning");
});
