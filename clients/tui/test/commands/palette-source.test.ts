import { afterEach, describe, expect, test } from "bun:test";
import {
	daemonFileCommands,
	daemonSkillEntries,
	type PaletteEntry,
	rankPaletteEntries,
} from "../../src/commands/palette-source.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

let harness: Harness | undefined;

afterEach(() => {
	harness?.stop();
	harness = undefined;
});

function entry(name: string, aliases: string[], description: string): PaletteEntry {
	return {
		name,
		aliases,
		description,
		value: `command:${name}`,
		label: `/${name}`,
		kind: "command",
		insertText: `/${name}`,
		available: true,
	};
}

describe("fuzzy palette search", () => {
	test("exact alias wins over description; names and descriptions match fuzzily", () => {
		const entries = [
			entry("debug", [], "reasoning log"),
			entry("think", ["reasoning"], "set model effort"),
			entry("reset", [], "forget durable conversation"),
		];
		expect(rankPaletteEntries(entries, "/reasoning")[0].name).toBe("think");
		expect(rankPaletteEntries(entries, "effort").map((item) => item.name)).toContain("think");
		expect(rankPaletteEntries(entries, "frgt").map((item) => item.name)).toContain("reset");
		expect(rankPaletteEntries(entries, "")).toEqual(entries);
	});
});

describe("daemon file commands", () => {
	test("maps commands.list for the cwd, dropping malformed entries", async () => {
		harness = await createHarness();
		harness.server.respondWith("commands.list", {
			commands: [
				{ name: "deploy", description: "Deploy it", argumentHint: "[env]" },
				{ name: "git:commit", description: "", argumentHint: null },
				{ name: "two words", description: "", argumentHint: null },
				{ name: 7, description: "" },
			],
			truncated: true,
		});
		const result = await daemonFileCommands(harness.methods, "/work/project");
		expect(harness.server.requestsFor("commands.list")[0].params).toEqual({
			cwd: "/work/project",
		});
		expect(
			result.commands.map((command) => [command.name, command.summary, command.usage]),
		).toEqual([
			["deploy", "Deploy it", "[env]"],
			["git:commit", "file command", undefined],
		]);
		expect(result.issues).toEqual(["The daemon listed only the first 2 file commands."]);
	});

	test("a failed read throws so the registry keeps its previous set", async () => {
		harness = await createHarness();
		harness.server.failWith("commands.list", "UNAVAILABLE", "Slash commands are unavailable");
		await expect(daemonFileCommands(harness.methods, "/work")).rejects.toThrow();
		harness.server.respondWith("commands.list", { commands: "nope" });
		await expect(daemonFileCommands(harness.methods, "/work")).rejects.toThrow(/invalid/);
	});

	test("a daemon without commands.list sends nothing and says so", async () => {
		harness = await createHarness({ methods: ["chat.send"] });
		const result = await daemonFileCommands(harness.methods, "/work");
		expect(result.commands).toEqual([]);
		expect(result.issues.join(" ")).toContain("commands.list");
		expect(harness.server.requestsFor("commands.list")).toHaveLength(0);
	});
});

describe("daemon skills", () => {
	test("lists skills.list entries with disabled skills explained", async () => {
		harness = await createHarness();
		harness.server.respondWith("skills.list", {
			skills: [
				{ key: "review", description: "Review code", enabled: true },
				{ key: "off", description: "", enabled: false },
				{ key: "" },
			],
			summary: { truncated: false },
		});
		const result = await daemonSkillEntries(harness.methods, "/work");
		expect(harness.server.requestsFor("skills.list")[0].params).toEqual({ cwd: "/work" });
		expect(result.issues).toEqual([]);
		expect(
			result.entries.map((item) => [item.label, item.description, item.available, item.reason]),
		).toEqual([
			["skill:review", "Review code", true, undefined],
			["skill:off", "skill", false, "skill is disabled"],
		]);
	});

	test("a failed read is an issue, never an empty success", async () => {
		harness = await createHarness();
		harness.server.failWith("skills.list", "UNAVAILABLE", "Skill registry is unavailable");
		const result = await daemonSkillEntries(harness.methods, "/work");
		expect(result.entries).toEqual([]);
		expect(result.issues.join(" ")).toContain("Skill discovery failed");
	});
});
