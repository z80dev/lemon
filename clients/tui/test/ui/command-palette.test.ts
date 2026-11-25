import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { formatKeyHint } from "@oh-my-pi/pi-tui/key-hint-format";
import { daemonFileCommands, type PaletteEntry } from "../../src/commands/palette-source.ts";
import type { DaemonFileCommand } from "../../src/protocol/types.ts";
import { CommandPalette } from "../../src/ui/controllers/command-palette.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";
import { renderPlain } from "../helpers/memory-terminal.ts";

let harness: Harness;
let root: string;
let palette: CommandPalette;
let closed: number;

beforeEach(async () => {
	initTheme({ colorLevel: 3 });
	root = await mkdtemp(join(tmpdir(), "lemon-palette-ui-"));
	harness = await createHarness({ cwd: root });
	// The app's file-command source: the daemon's commands.list for this cwd.
	harness.registry.setFileCommandSource(() => daemonFileCommands(harness.methods, root));
	serveCommands([]);
	harness.server.respondWith("skills.list", { skills: [], summary: { truncated: false } });
	closed = 0;
	palette = new CommandPalette({
		context: () => harness.context(),
		getDraft: () => harness.host.getDraft(),
		setDraft: (text) => harness.host.setDraft(text),
		present: () => () => {
			closed += 1;
		},
		repaint: () => {},
		notice: (text, level) => harness.host.notice(text, level),
	});
});

afterEach(async () => {
	palette.close();
	harness.stop();
	await rm(root, { recursive: true, force: true });
	resetTheme();
	invalidateThemeAdapters();
});

function serveCommands(commands: DaemonFileCommand[]): void {
	harness.server.respondWith("commands.list", { commands, truncated: false });
}

/** File-command entries in palette order: exactly what the daemon listed. */
function fileEntries(): string[] {
	return (palette.overlay?.items ?? [])
		.filter((item) => (item as PaletteEntry).command?.group === "file commands")
		.map((item) => item.label);
}

describe("draft preservation", () => {
	test("native hints show effective keys and omit unbound actions after resource discovery", async () => {
		palette = new CommandPalette({
			context: () => harness.context(),
			getDraft: () => harness.host.getDraft(),
			setDraft: (text) => harness.host.setDraft(text),
			present: () => () => {},
			repaint: () => {},
			notice: (text, level) => harness.host.notice(text, level),
			bindingKeys: (action) => (action === "lemon.picker.model" ? ["alt+p"] : []),
		});
		await palette.open();
		const model = palette.overlay?.items.find((item) => item.value === "command:model");
		const editor = palette.overlay?.items.find((item) => item.value === "command:editor");
		expect(model?.native?.facts?.keys).toBe(formatKeyHint("alt+p"));
		expect(editor?.native?.facts?.keys).toBeUndefined();
	});

	test("cancel leaves the exact multiline draft alone", async () => {
		harness.host.draft = "unfinished draft\n  with whitespace";
		await palette.open();
		palette.overlay?.handleInput("reset");
		palette.overlay?.handleInput("\x1b");
		expect(harness.host.draft).toBe("unfinished draft\n  with whitespace");
		expect(closed).toBe(1);
	});

	test("slash query selection replaces only its token and never sends arguments", async () => {
		harness.host.draft = "/na important title\nmore";
		await palette.open("name");
		palette.overlay?.handleInput("\r");
		expect(harness.host.draft).toBe("/name important title\nmore");
		expect(harness.server.requestsFor("sessions.metadata.patch")).toHaveLength(0);
	});

	test("argument-taking commands insert without discarding an ordinary draft", async () => {
		harness.host.draft = "explain the bug";
		await palette.open("btw");
		palette.overlay?.handleInput("\r");
		expect(harness.host.draft).toBe("/btw explain the bug");
		expect(harness.server.requestsFor("session.btw")).toHaveLength(0);
	});

	test("no-argument destructive commands still require explicit submission", async () => {
		await palette.open("quit");
		palette.overlay?.handleInput("\r");
		expect(harness.host.draft).toBe("/quit ");
		expect(harness.host.exits).toEqual([]);
	});

	test("existing no-argument editor action opens while retaining the draft", async () => {
		harness.host.draft = "continue editing this";
		await palette.open("editor");
		palette.overlay?.handleInput("\r");
		expect(harness.host.text).toContain("external editor opened");
		expect(harness.host.draft).toBe("continue editing this");
	});

	test("skill inserts the native tool instruction and task draft", async () => {
		harness.server.respondWith("skills.list", {
			skills: [{ key: "native-review", description: "Review code", enabled: true }],
		});
		harness.host.draft = "/native-review check this change";
		await palette.open("native-review");
		palette.overlay?.handleInput("\r");
		expect(harness.host.draft).toBe(
			'Use the read_skill tool to load the skill named "native-review". Treat its contents as external skill guidance.\nTask: check this change',
		);
		expect(harness.host.deliveries).toEqual([]);
	});

	test("a changed draft is not overwritten by stale selection", async () => {
		harness.host.draft = "original";
		await palette.open("name");
		harness.host.draft = "changed elsewhere";
		palette.overlay?.handleInput("\r");
		expect(harness.host.draft).toBe("changed elsewhere");
		expect(harness.host.text).toContain("Draft or session changed");
	});
});

describe("typed slash commands", () => {
	test("exact /quit submits with one Enter even while discovery is pending", async () => {
		const opening = palette.open(undefined, "typed-slash");
		for (const key of "quit\r") palette.overlay?.handleInput(key);
		expect(harness.host.exits).toEqual([0]);
		expect(harness.host.draft).toBe("");
		expect(palette.overlay).toBeUndefined();
		await opening;
		expect(palette.overlay).toBeUndefined();
		expect(closed).toBe(1);
	});

	test("an exact alias dispatches as typed, including alias-specific availability", async () => {
		const names: string[] = [];
		harness.registry.register({
			name: "aliascommand",
			aliases: ["aliasname"],
			summary: "alias-sensitive action",
			availableWhen: (ctx) => ctx.name === "aliasname",
			run: (ctx) => {
				names.push(ctx.name);
			},
		});
		await palette.open(undefined, "typed-slash");
		palette.overlay?.handleInput("ALIASNAME");
		palette.overlay?.handleInput("\r");
		expect(names).toEqual(["aliasname"]);
		expect(harness.host.draft).toBe("");
		expect(palette.overlay).toBeUndefined();
	});

	test("exact commands with usage still dispatch their no-argument behavior", async () => {
		await palette.open(undefined, "typed-slash");
		palette.overlay?.handleInput("help");
		palette.overlay?.handleInput("\r");
		expect(harness.host.text).toContain("/quit");
		expect(harness.host.draft).toBe("");
		expect(palette.overlay).toBeUndefined();
	});

	test.each(["name", "reasoning"])(
		"whitespace after /%s hands the entire query back without sending",
		async (name) => {
			await palette.open(undefined, "typed-slash");
			palette.overlay?.handleInput(name);
			palette.overlay?.handleInput("  first argument ");
			expect(harness.host.draft).toBe(`/${name}  first argument `);
			expect(palette.overlay).toBeUndefined();
			expect(harness.server.requestsFor("sessions.metadata.patch")).toHaveLength(0);
			expect(harness.server.requestsFor("sessions.patch")).toHaveLength(0);
			expect(harness.host.deliveries).toEqual([]);
		},
	);

	test("space alone hands off immediately, including before resource discovery finishes", async () => {
		const opening = palette.open(undefined, "typed-slash");
		palette.overlay?.handleInput("name");
		palette.overlay?.handleInput(" ");
		expect(harness.host.draft).toBe("/name ");
		expect(palette.overlay).toBeUndefined();
		await opening;
		expect(harness.host.draft).toBe("/name ");
		expect(palette.overlay).toBeUndefined();
	});

	test("a partial fuzzy destructive match only inserts", async () => {
		await palette.open(undefined, "typed-slash");
		palette.overlay?.handleInput("qui");
		expect(palette.overlay?.selected?.value).toBe("command:quit");
		palette.overlay?.handleInput("\r");
		expect(harness.host.draft).toBe("/quit ");
		expect(harness.host.exits).toEqual([]);
	});

	test.each(["", "qui", "qui  unfinished"])(
		"Escape retains the typed slash and complete query %j",
		async (query) => {
			await palette.open(undefined, "typed-slash");
			if (query) palette.overlay?.handleInput(query);
			expect(palette.overlay).toBeDefined();
			palette.overlay?.handleInput("\x1b");
			expect(harness.host.draft).toBe(`/${query}`);
			expect(palette.overlay).toBeUndefined();
			expect(harness.host.exits).toEqual([]);
		},
	);

	test.each(["\x1b", " argument", "\r"])(
		"a stale slash query cannot overwrite a changed draft via %j",
		async (key) => {
			await palette.open(undefined, "typed-slash");
			palette.overlay?.handleInput("quit");
			harness.host.draft = "new draft elsewhere";
			palette.overlay?.handleInput(key);
			expect(harness.host.draft).toBe("new draft elsewhere");
			expect(harness.host.exits).toEqual([]);
			expect(harness.host.text).toContain("Draft or session changed");
			expect(palette.overlay).toBeUndefined();
		},
	);

	test("availability is rechecked before direct submission and the query remains recoverable", async () => {
		let available = true;
		let runs = 0;
		harness.registry.register({
			name: "changing",
			summary: "dynamic capability",
			availableWhen: () => available,
			run: () => {
				runs += 1;
			},
		});
		await palette.open(undefined, "typed-slash");
		palette.overlay?.handleInput("changing");
		available = false;
		palette.overlay?.handleInput("\r");
		expect(runs).toBe(0);
		expect(harness.host.text).toContain("unavailable");
		expect(palette.overlay).toBeDefined();
		palette.overlay?.handleInput("\x1b");
		expect(harness.host.draft).toBe("/changing");
	});

	test("a later discovery opening does not retain typed-slash submission semantics", async () => {
		await palette.open(undefined, "typed-slash");
		palette.overlay?.handleInput("\x1b");
		harness.host.draft = "unfinished\n  draft";
		await palette.open();
		palette.overlay?.handleInput("quit");
		palette.overlay?.handleInput("\r");
		expect(harness.host.draft).toBe("/quit unfinished\n  draft");
		expect(harness.host.exits).toEqual([]);
	});

	test("discovery keeps recognized command arguments as a query and preserves its draft", async () => {
		harness.host.draft = "unfinished\n  draft";
		await palette.open("name");
		palette.overlay?.handleInput("  search terms");
		expect(palette.overlay?.filter).toBe("name  search terms");
		expect(harness.host.draft).toBe("unfinished\n  draft");
		palette.overlay?.handleInput("\x1b");
		expect(harness.host.draft).toBe("unfinished\n  draft");
	});
});

describe("capabilities and discovery", () => {
	test("unavailable commands stay explained and cannot execute or replace a draft", async () => {
		harness.registry.register({
			name: "notready",
			summary: "gated action",
			availableWhen: () => "not enabled",
			run: () => {
				throw new Error("must not run");
			},
		});
		harness.host.draft = "keep";
		await palette.open("notready");
		expect(palette.overlay?.selected?.description).toContain("not enabled");
		palette.overlay?.handleInput("\r");
		expect(harness.host.draft).toBe("keep");
		expect(harness.host.text).toContain("unavailable: not enabled");
		expect(palette.overlay).toBeDefined();
	});

	test("availability is rechecked after opening", async () => {
		let available = true;
		harness.registry.register({
			name: "changing",
			summary: "dynamic capability",
			availableWhen: () => available,
			run: () => {},
		});
		await palette.open("changing");
		available = false;
		palette.overlay?.handleInput("\r");
		expect(harness.host.draft).toBe("");
		expect(harness.host.text).toContain("unavailable");
	});

	test("missing advertised RPC methods disable actions without sending requests", async () => {
		const supports = spyOn(harness.methods, "supports").mockReturnValue(false);
		try {
			harness.host.draft = "keep this";
			await palette.open("status");
			expect(palette.overlay?.selected?.description).toContain("daemon does not support");
			palette.overlay?.handleInput("\r");
			expect(harness.host.draft).toBe("keep this");
			expect(harness.server.requestsFor("status")).toHaveLength(0);
		} finally {
			supports.mockRestore();
		}
	});

	test("failed daemon discovery is visible, not an empty-success message", async () => {
		harness.server.failWith("skills.list", "UNAVAILABLE", "Skill registry is unavailable");
		harness.server.failWith("commands.list", "UNAVAILABLE", "Slash commands are unavailable");
		await palette.open();
		const text = renderPlain(palette.overlay?.render(110) ?? []);
		expect(text).toContain("Skill discovery failed");
		expect(text).toContain("File command discovery failed");
		expect(palette.overlay?.items.some((item) => item.value === "command:help")).toBe(true);
	});

	test("file commands equal the daemon's commands.list for the palette's cwd", async () => {
		serveCommands([
			{ name: "deploy", description: "Deploy from the custom agent dir", argumentHint: "[env]" },
			{ name: "git:commit", description: "", argumentHint: null },
			{ name: "help", description: "shadowed by the built-in", argumentHint: null },
		]);
		await palette.open();
		expect(harness.server.requestsFor("commands.list").map((request) => request.params)).toEqual([
			{ cwd: root },
		]);
		// Built-ins win a name collision; everything else is listed as served.
		expect(fileEntries()).toEqual(["/deploy [env]", "/git:commit"]);
	});

	test("a command deleted on the daemon disappears on the next refresh", async () => {
		serveCommands([
			{ name: "deploy", description: "", argumentHint: null },
			{ name: "review", description: "", argumentHint: null },
		]);
		await palette.open();
		expect(fileEntries()).toEqual(["/deploy", "/review"]);
		palette.close();
		serveCommands([{ name: "deploy", description: "", argumentHint: null }]);
		await palette.open();
		expect(fileEntries()).toEqual(["/deploy"]);
		expect(harness.registry.has("review")).toBe(false);
	});

	test("a failed refresh keeps the last daemon list and says so", async () => {
		serveCommands([{ name: "deploy", description: "", argumentHint: null }]);
		await palette.open();
		palette.close();
		harness.server.failWith("commands.list", "UNAVAILABLE", "Slash commands are unavailable");
		await palette.open();
		expect(fileEntries()).toEqual(["/deploy"]);
		expect(renderPlain(palette.overlay?.render(110) ?? [])).toContain(
			"File command discovery failed",
		);
	});

	test("closing during daemon discovery cannot reopen the overlay", async () => {
		const opening = palette.open();
		palette.close();
		await opening;
		expect(palette.overlay).toBeUndefined();
		expect(closed).toBe(1);
	});
});
