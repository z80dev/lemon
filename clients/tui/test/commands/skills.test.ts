import { afterEach, beforeEach, describe, expect, test } from "bun:test";
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

describe("/skills", () => {
	test("opens the live Hermes category picker", async () => {
		harness.server.respondWith("skills.hermes.catalog", {
			skills: [],
			categories: [{ collection: "bundled", category: "research", count: 8, installedCount: 1 }],
			summary: { count: 203, categoryCount: 25, installedCount: 1 },
		});

		await harness.run("/skills");
		expect(harness.host.pickers).toHaveLength(1);
		expect(harness.host.pickers[0].title).toContain("203 skills");
		expect(harness.host.pickers[0].items[0].description).toContain("8 skills");
	});

	test("search opens a multi-select list and imports the selected ids", async () => {
		harness.server.respondWith("skills.hermes.catalog", {
			skills: [
				{
					id: "hermes:optional/research/arxiv",
					key: "arxiv",
					name: "arxiv",
					description: "Search papers.",
					category: "research",
					collection: "optional",
					installed: false,
				},
			],
			categories: [],
			summary: { count: 1, categoryCount: 1, installedCount: 0 },
		});
		harness.server.respondWith("skills.install", { installed: true, skillKey: "arxiv" });

		await harness.run("/skills arxiv");
		expect(harness.host.multiPickers).toHaveLength(1);
		const picker = harness.host.multiPickers[0];
		expect(picker.items[0].description).toBe("Search papers.");
		await picker.onConfirm([picker.items[0]]);

		expect(harness.server.requestsFor("skills.install")[0].params).toEqual({
			skillKey: "hermes:optional/research/arxiv",
		});
		expect(harness.host.text).toContain("Imported 1/1");
	});

	test("marks already installed skills as disabled", async () => {
		harness.server.respondWith("skills.hermes.catalog", {
			skills: [
				{
					id: "hermes:bundled/apple/apple-notes",
					key: "apple-notes",
					name: "apple-notes",
					description: "Notes.",
					category: "apple",
					collection: "bundled",
					installed: true,
				},
			],
			categories: [],
			summary: { count: 1, categoryCount: 1, installedCount: 1 },
		});

		await harness.run("/skills notes");
		expect(harness.host.multiPickers[0].disabledValues).toEqual([
			"hermes:bundled/apple/apple-notes",
		]);
	});
});
