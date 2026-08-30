import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { SlashCommand } from "../../src/commands/registry.ts";
import { CommandRegistry, parseCommandLine, splitArgs } from "../../src/commands/registry.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

let harness: Harness | undefined;

beforeEach(() => {
	initTheme({ colorLevel: 3 });
});

afterEach(() => {
	harness?.stop();
	harness = undefined;
	resetTheme();
	invalidateThemeAdapters();
});

describe("parseCommandLine", () => {
	test("splits a command from its arguments", () => {
		expect(parseCommandLine("/model claude-sonnet-4")).toEqual({
			name: "model",
			argv: ["claude-sonnet-4"],
			rest: "claude-sonnet-4",
		});
	});

	test("lowercases the name and tolerates leading whitespace", () => {
		expect(parseCommandLine("   /HELP")?.name).toBe("help");
	});

	test("keeps the rest verbatim for free-text arguments", () => {
		expect(parseCommandLine("/goal set ship the release  today")?.rest).toBe(
			"set ship the release  today",
		);
	});

	test("ordinary prompts and paths are not commands", () => {
		expect(parseCommandLine("what is /usr/bin?")).toBeNull();
		expect(parseCommandLine("/")).toBeNull();
		expect(parseCommandLine("/usr/bin/env")).toBeNull();
		expect(parseCommandLine("hello")).toBeNull();
	});

	test("quoted arguments stay one token", () => {
		expect(splitArgs(`set "two words" tail`)).toEqual(["set", "two words", "tail"]);
	});
});

describe("CommandRegistry", () => {
	const echo: SlashCommand = {
		name: "echo",
		aliases: ["e"],
		summary: "echo the arguments",
		run(ctx, argv) {
			ctx.ui.notice(`echo:${argv.join("|")}`);
		},
	};

	test("dispatches by name and by alias", async () => {
		harness = await createHarness();
		harness.registry.register(echo);
		expect(await harness.run("/echo a b")).toBe(true);
		expect(await harness.run("/e c")).toBe(true);
		expect(harness.host.notices.map((n) => n.text)).toEqual(["echo:a|b", "echo:c"]);
	});

	test("returns false for a line that is not a command", async () => {
		harness = await createHarness();
		expect(await harness.run("just a prompt")).toBe(false);
		expect(harness.host.notices).toHaveLength(0);
	});

	test("an unknown command is reported, not sent", async () => {
		harness = await createHarness();
		expect(await harness.run("/nope")).toBe(true);
		expect(harness.host.last?.level).toBe("error");
		expect(harness.host.text).toContain("unknown command /nope");
	});

	test("a throwing command becomes an error notice", async () => {
		harness = await createHarness();
		harness.registry.register({
			name: "boom",
			summary: "always fails",
			run() {
				throw new Error("kaboom");
			},
		});
		await harness.run("/boom");
		expect(harness.host.last?.level).toBe("error");
		expect(harness.host.text).toContain("kaboom");
	});

	test("duplicate names are a programming error", () => {
		const registry = new CommandRegistry().register(echo);
		expect(() => registry.register({ ...echo })).toThrow(/duplicate/);
	});
});

describe("availability gating", () => {
	test("a command whose method is missing is disabled", async () => {
		harness = await createHarness({ methods: ["chat.send", "health"] });
		const ctx = harness.context();
		const status = harness.registry.get("status");
		expect(status).toBeDefined();
		const availability = harness.registry.availability(status!, ctx);
		expect(availability.available).toBe(false);
		expect(availability.reason).toContain("status");
	});

	test("running a disabled command explains itself instead of dialing", async () => {
		harness = await createHarness({ methods: ["chat.send"] });
		await harness.run("/usage");
		expect(harness.host.last?.level).toBe("warning");
		expect(harness.host.text).toContain("usage.status");
		expect(harness.server.requestsFor("usage.status")).toHaveLength(0);
	});

	test("availableWhen can disable a command with a reason", async () => {
		harness = await createHarness();
		harness.registry.register({
			name: "gated",
			summary: "never available",
			availableWhen: () => "not today",
			run() {
				throw new Error("must not run");
			},
		});
		await harness.run("/gated");
		expect(harness.host.text).toContain("not today");
	});

	test("commands are available when every backing method is advertised", async () => {
		harness = await createHarness();
		const ctx = harness.context();
		for (const command of harness.registry.list()) {
			const availability = harness.registry.availability(command, ctx);
			expect(availability.available).toBe(true);
		}
	});
});

describe("/help", () => {
	test("lists every registered command and marks disabled ones", async () => {
		harness = await createHarness({ methods: ["chat.send"] });
		await harness.run("/help");
		const help = harness.host.text;
		for (const command of harness.registry.list()) {
			expect(help).toContain(`/${command.name}`);
		}
		expect(help).toContain("disabled:");
		expect(help).toContain("!cmd");
	});

	test("explains a single command", async () => {
		harness = await createHarness();
		await harness.run("/help model");
		expect(harness.host.text).toContain("/model");
		expect(harness.host.text).toContain("sessions.patch");
	});

	test("says so when asked about a command that does not exist", async () => {
		harness = await createHarness();
		await harness.run("/help nonesuch");
		expect(harness.host.text).toContain("no such command");
	});
});

describe("/commands", () => {
	test("falls back to the local registry when commands.catalog is absent", async () => {
		harness = await createHarness({ methods: ["chat.send"] });
		await harness.run("/commands queue");
		expect(harness.host.text).toContain("local fallback");
		expect(harness.host.text).toContain("/queue [prompt]");
	});

	test("capability-gates background and btw against older daemons", async () => {
		harness = await createHarness({ methods: ["chat.send"] });
		await harness.run("/bg do work");
		await harness.run("/btw a question");
		expect(harness.host.text).toContain("background.start");
		expect(harness.host.text).toContain("session.btw");
		expect(harness.server.requestsFor("background.start")).toHaveLength(0);
		expect(harness.server.requestsFor("session.btw")).toHaveLength(0);
	});
});
