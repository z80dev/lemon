import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import type { DescribeContext, NativeNode } from "@oh-my-pi/pi-tui/native/node";
import { TERMINAL } from "@oh-my-pi/pi-tui/terminal-capabilities";
import { fixtureBlock, fixtureByName } from "../src/dev/fixtures/tool-fixtures.ts";
import type { ToolBlock } from "../src/store/transcript-model.ts";
import { fileTarget, toolLocation } from "../src/terminal/links.ts";
import { diffNode } from "../src/terminal/native-tool-view.ts";
import { accordionSettings } from "../src/ui/components/accordion.ts";
import { ToolCardComponent } from "../src/ui/components/tool-card.ts";
import { ToolShelfComponent } from "../src/ui/components/tool-shelf.ts";
import { initTheme, resetTheme } from "../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../src/ui/theme/tui-adapters.ts";

let hyperlinks: boolean;
beforeEach(() => {
	hyperlinks = TERMINAL.hyperlinks;
	TERMINAL.hyperlinks = true;
	accordionSettings.reset();
	initTheme({ colorLevel: 3 });
});
afterEach(() => {
	TERMINAL.hyperlinks = hyperlinks;
	accordionSettings.reset();
	resetTheme();
	invalidateThemeAdapters();
});

function block(
	name: string,
	args: Record<string, unknown>,
	details: Record<string, unknown> = {},
): ToolBlock {
	const fixture = fixtureByName(name);
	if (!fixture) throw new Error(`no fixture ${name}`);
	return fixtureBlock({ ...fixture, completed: { name, args, details, result: "" } }, "success");
}

/** `target`: the head text, which names an edit's changed line or a read's range after the path. */
function expectTarget(tool: ToolBlock, path: string, line?: number, target = path): void {
	const url = pathToFileURL(resolve(path));
	if (line !== undefined) url.hash = `L${line}`;
	const card = new ToolCardComponent(tool);
	const native = card.describe();
	if (native.k !== "tool") throw new Error("expected native tool node");
	expect(native.p?.target).toBe(target);
	expect(native.p?.targetKind).toBe("path");
	expect(native.p?.href).toBe(url.href);
	expect(card.render(240).join("\n")).toContain(`\x1b]8;;${url.href}\x07`);
	card.setCompact(true);
	expect(card.render(240).join("\n")).toContain(`\x1b]8;;${url.href}\x07`);
}

test("native edit receipt and both row forms link the tool's actual changed line", () => {
	const fixture = fixtureByName("edit");
	if (!fixture) throw new Error("no edit fixture");
	expectTarget(
		fixtureBlock(fixture, "success"),
		"clients/tui/src/store/transcript-model.ts",
		121,
		"clients/tui/src/store/transcript-model.ts:121",
	);
});

test("result paths win over relative arguments; read offsets and file_path reach native links", () => {
	expectTarget(
		block(
			"edit",
			{ path: "other.ts", offset: 2 },
			{
				path: "/repo/日本語 space#file.ts",
				first_changed_line: 42,
			},
		),
		"/repo/日本語 space#file.ts",
		42,
		"/repo/日本語 space#file.ts:42",
	);
	expectTarget(
		block("read", { file_path: "src/read me.ts", offset: 17 }),
		"src/read me.ts",
		17,
		"src/read me.ts:17",
	);
	expectTarget(
		block("write", {}, { path: "/repo/new.ts", oldText: null, newText: "new\n" }),
		"/repo/new.ts",
		1,
	);
});

test("an empty todo receipt does not revive the proposed checklist", () => {
	const card = new ToolCardComponent(
		block(
			"todo",
			{ action: "write", todos: [{ content: "Abandoned", status: "pending" }] },
			{ todos: [] },
		),
	);
	expect(JSON.stringify(card.describe())).not.toContain("Abandoned");
	expect(card.render(120).join("\n")).not.toContain("Abandoned");
});

test("native todo checklist preserves phase groups and blocked reasons", () => {
	const card = new ToolCardComponent(
		block(
			"todo",
			{ action: "read" },
			{
				todos: [
					{ content: "Deploy", status: "blocked", phase: "Release", blocker: "Need access" },
					{ content: "Old approach", status: "abandoned", phase: "Archive" },
				],
			},
		),
	);
	const description = JSON.stringify(card.describe());
	expect(description).toContain("Release");
	expect(description).toContain("Archive");
	expect(description).toContain("Need access");
	expect(description).toContain("1/2");
});

test("structured paths with fragment-like names stay literal, with controls rejected", () => {
	expectTarget(
		block("edit", { path: "src/name#L42" }, { first_changed_line: 7 }),
		"src/name#L42",
		7,
		"src/name#L42:7",
	);
	expectTarget(block("read", { path: "src/name:42" }), "src/name:42");
	for (const path of ["bad\x1b]9;inject\x07", "bad\nfile", "bad\u009b31m"]) {
		const tool = block("edit", { path }, { first_changed_line: 42 });
		expect(toolLocation(tool)).toBeUndefined();
		expect(fileTarget(path, 42)).toBeUndefined();
		const native = new ToolCardComponent(tool).describe();
		expect(native.p?.href).toBeUndefined();
	}
});

test("patch receipts use the first surviving destination and its bounded snapshot line", () => {
	expectTarget(
		block(
			"patch",
			{},
			{
				changed: ["/repo/deleted.ts", "/repo/moved #日本語.ts", "/repo/other.ts"],
				perFileResults: [
					{ path: "/repo/deleted.ts", oldText: "old\n", newText: null },
					{ path: "/repo/old-name.ts", oldText: "old\n", newText: null },
					{
						path: "/repo/moved #日本語.ts",
						oldText: "one\ntwo\nold\n",
						newText: "one\ntwo\nnew\n",
					},
					{ path: "/repo/other.ts", oldText: "old\n", newText: "new\n" },
				],
			},
		),
		"/repo/moved #日本語.ts",
		3,
	);
	expectTarget(block("patch", {}, { changed: ["/repo/large.ts"] }), "/repo/large.ts");
	expect(
		toolLocation(
			block(
				"patch",
				{},
				{
					changed: ["/repo/deleted.ts"],
					perFileResults: [{ path: "/repo/deleted.ts", oldText: "old", newText: null }],
				},
			),
		),
	).toBeUndefined();
});

test("invalid line metadata is ignored without dropping a valid read offset", () => {
	for (const first_changed_line of [0, -1, 1.5, Number.NaN, Number.POSITIVE_INFINITY, "42"]) {
		expectTarget(
			block("read", { path: "src/read.ts", offset: 9 }, { first_changed_line }),
			"src/read.ts",
			9,
			"src/read.ts:9",
		);
	}
});

test("unstructured result prose never becomes a file target", () => {
	const tool = block("patch", { patch: "*** Update File: /repo/guess.ts\n@@\n-old\n+new" });
	tool.detail = { ...tool.detail, result: "Edited /repo/guess.ts:42 successfully" };
	expect(toolLocation(tool)).toBeUndefined();
	const native = new ToolCardComponent(tool).describe();
	expect(native.p?.href).toBeUndefined();
});

function isNode(value: unknown): value is NativeNode {
	return typeof value === "object" && value !== null && "k" in value;
}

/** Every node under `root`, depth first (components are skipped). */
function nodes(root: NativeNode): NativeNode[] {
	return [root, ...(root.c ?? []).filter(isNode).flatMap(nodes)];
}

/** One prop of a described node. */
function prop(n: NativeNode | undefined, key: string): unknown {
	return n?.p ? Reflect.get(n.p, key) : undefined;
}

function withRole(root: NativeNode, role: string): NativeNode[] {
	return nodes(root).filter((n) => prop(n, "role") === role);
}

function settled(name: string, detail: Record<string, unknown>, ok = true): ToolBlock {
	const fixture = fixtureByName(name);
	if (!fixture) throw new Error(`no fixture ${name}`);
	return fixtureBlock(
		ok
			? { ...fixture, completed: { name, ...detail } }
			: { ...fixture, failed: { name, ...detail } },
		ok ? "success" : "error",
	);
}

function mediaContext(supported: boolean): DescribeContext {
	return {
		cols: 100,
		dark: true,
		reduceMotion: false,
		supports: (kind) => kind !== "media" || supported,
		feature: () => false,
	};
}

test("native read media requires negotiated support and an existing local path", () => {
	const dir = mkdtempSync(join(tmpdir(), "lemon-native-media-"));
	const path = join(dir, "drawing.svg");
	writeFileSync(path, "<svg xmlns='http://www.w3.org/2000/svg'/>");
	try {
		const tool = settled("read", {
			args: { path },
			result: "",
			details: { media_path: path },
		});
		const card = new ToolCardComponent(tool);
		const rows = card.render(120).join("\n");
		expect(nodes(card.describe(mediaContext(false))).filter((n) => n.k === "media")).toEqual([]);
		const media = nodes(card.describe(mediaContext(true))).filter((n) => n.k === "media");
		expect(media).toHaveLength(1);
		expect(media[0]?.p?.path).toBe(path);
		expect(card.render(120).join("\n")).toBe(rows);
		expect(nodes(card.describe(mediaContext(false))).some((n) => n.k === "media")).toBe(false);

		for (const details of [
			{ media_path: join(dir, "remote.svg") },
			{ media_path: "drawing.svg" },
			{ path },
		]) {
			const missing = new ToolCardComponent(settled("read", { details, result: "1: text" }));
			expect(nodes(missing.describe(mediaContext(true))).some((n) => n.k === "media")).toBe(false);
		}

		const failed = new ToolCardComponent(settled("read", { details: { media_path: path } }, false));
		expect(nodes(failed.describe(mediaContext(true))).some((n) => n.k === "media")).toBe(false);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("opened read groups retain media and invalidate their cache when host capabilities change", () => {
	const dir = mkdtempSync(join(tmpdir(), "lemon-native-media-"));
	const path = join(dir, "drawing.svg");
	writeFileSync(path, "<svg xmlns='http://www.w3.org/2000/svg'/>");
	try {
		const shelf = new ToolShelfComponent();
		for (const id of ["media-read-1", "media-read-2"]) {
			const tool = settled("read", { args: { path }, details: { media_path: path } });
			tool.id = id;
			shelf.add(tool);
		}
		const group = shelf.describe(mediaContext(true)).c?.[0];
		if (!isNode(group)) throw new Error("expected read group");
		shelf.handleNativeEvent({ type: "toggle", key: group.key!, collapsed: false });
		expect(nodes(shelf.describe(mediaContext(true))).filter((n) => n.k === "media")).toHaveLength(
			2,
		);
		expect(nodes(shelf.describe(mediaContext(false))).some((n) => n.k === "media")).toBe(false);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("browser screenshot cards display only the saved artifact path in their result details", () => {
	const dir = mkdtempSync(join(tmpdir(), "lemon-native-media-"));
	const path = join(dir, "screenshot.png");
	writeFileSync(path, "saved screenshot");
	try {
		const screenshot = (details: Record<string, unknown>) =>
			new ToolCardComponent(
				settled("browser_navigate", {
					name: "browser_screenshot",
					args: { path },
					result: "Screenshot saved",
					details,
				}),
			);
		expect(
			nodes(screenshot({ path }).describe(mediaContext(true))).filter((n) => n.k === "media"),
		).toHaveLength(1);
		expect(
			nodes(screenshot({ path }).describe(mediaContext(false))).some((n) => n.k === "media"),
		).toBe(false);
		expect(nodes(screenshot({}).describe(mediaContext(true))).some((n) => n.k === "media")).toBe(
			false,
		);
		expect(
			nodes(screenshot({ path: join(dir, "remote.png") }).describe(mediaContext(true))).some(
				(n) => n.k === "media",
			),
		).toBe(false);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});

test("a failed command is a run box with the daemon's notices moved into the exit chip", () => {
	const native = new ToolCardComponent(
		settled(
			"bash",
			{
				args: { command: "ls nope" },
				result: "ls: nope: No such file or directory\n\nCommand exited with code 2",
				details: { exit_code: 2 },
				result_meta: { error_type: "command_exit", exit_code: 2 },
			},
			false,
		),
	).describe();
	expect(native.p).toMatchObject({
		role: "omp.tool.bash",
		command: "ls nope",
		exit: 2,
		status: "error",
	});
	for (const role of ["omp.run", "omp.tool.bash.command", "omp.run.foot"]) {
		expect(withRole(native, role)).toHaveLength(1);
	}
	const [output] = withRole(native, "omp.tool.bash.output");
	expect(prop(output, "text")).toBe("ls: nope: No such file or directory");
});

test("grep output groups matches by file, marking match lines and linking each file", () => {
	const native = new ToolCardComponent(
		settled("grep", {
			args: { pattern: "upsertTool", path: "src", context_lines: 1 },
			result:
				"Found 2 matches.\n\nstore/a.ts-11- before\nstore/a.ts:12: upsertTool(\nui/b.ts:3: upsertTool()",
			details: { match_count: 2, truncated: false },
		}),
	).describe();
	expect(native.p).toMatchObject({ target: "upsertTool", meta: ["2 matches · 2 files", "in src"] });
	const files = withRole(native, "omp.tool.search.file");
	expect(files).toHaveLength(2);
	const code = nodes(files[0]!).find((n) => n.k === "code");
	expect(code?.p).toMatchObject({ start: 11, marks: [{ line: 12, tone: "accent" }] });
	expect(JSON.stringify(files[0])).toContain(String(fileTarget("src/store/a.ts", 12)));
});

test("gapped grep matches keep the file grammar and one horizontally scrolling code block", () => {
	const native = new ToolCardComponent(
		settled("grep", {
			args: { pattern: "entry", path: "/repo" },
			result: "Found 2 matches.\n\nkernel.ptx:2: .entry first()\nkernel.ptx:17: .entry second()",
			details: { match_count: 2 },
		}),
	).describe();
	const code = nodes(native).filter((child) => child.k === "code");
	expect(code).toHaveLength(1);
	expect(code[0]?.p).toMatchObject({ path: "kernel.ptx", nums: [2, 17] });
	expect(prop(code[0], "lang")).toBeUndefined();
});

test("read, write and diff send the file path without overriding Tern's grammar", () => {
	for (const tool of [
		settled("read", {
			args: { path: "kernel.ptx" },
			result: "7: .entry main()",
			details: { start_line: 7 },
		}),
		settled("write", { args: { path: "kernel.ptx", content: ".entry main()" } }),
	]) {
		const code = nodes(new ToolCardComponent(tool).describe()).find((child) => child.k === "code");
		expect(prop(code, "path")).toBe("kernel.ptx");
		expect(prop(code, "lang")).toBeUndefined();
	}
	for (const rows of ["-7|old\n+7|new", "-old\n+new"]) {
		const diff = diffNode(rows, "kernel.ptx");
		expect(prop(diff, "path")).toBe("kernel.ptx");
		expect(prop(diff, "lang")).toBeUndefined();
	}
});

test("Tern's disclosure opens a native card; nested disclosures keep their own state", () => {
	const card = new ToolCardComponent(fixtureBlock(fixtureByName("bash")!, "success"));
	expect(card.describe().p).toMatchObject({ collapsed: true });
	card.handleNativeEvent({ type: "toggle", key: "run", collapsed: false });
	expect(card.describe().p).toMatchObject({ collapsed: true });
	card.handleNativeEvent({ type: "toggle", key: "", collapsed: false });
	expect(card.describe().p).toMatchObject({ collapsed: false });
	card.handleNativeEvent({ type: "toggle", key: "", collapsed: true });
	expect(card.describe().p).toMatchObject({ collapsed: true });
});

test("consecutive settled reads fold into one native read group that opens to their content", () => {
	const shelf = new ToolShelfComponent();
	const read = (id: string, path: string, offset: number) => {
		const tool = settled("read", {
			args: { path, offset, limit: 2 },
			result: `${offset}: one\n${offset + 1}: two`,
			details: { path, start_line: offset, lines_shown: 2, total_lines: 99 },
		});
		tool.id = id;
		return tool;
	};
	shelf.add(read("r1", "src/a.ts", 5));
	shelf.add(read("r2", "src/b.ts", 7));
	const bash = fixtureBlock(fixtureByName("bash")!, "success");
	bash.id = "b1";
	shelf.add(bash);
	const described = shelf.describe();
	expect(shelf.describe()).toBe(described);
	const [group, card] = described.c ?? [];
	if (!isNode(group)) throw new Error("expected the read group node first");
	expect(card === shelf.cardFor("b1")).toBe(true);
	expect(group.p).toMatchObject({ role: "omp.tool.read", target: "2 files", collapsed: true });
	const rows = withRole(group, "omp.tool.file");
	expect(rows).toHaveLength(2);
	expect(JSON.stringify(rows[1])).toContain(String(fileTarget("src/b.ts", 7)));
	expect(nodes(group).some((n) => n.k === "section")).toBe(false);

	shelf.handleNativeEvent({ type: "toggle", key: group.key!, collapsed: false });
	const opened = shelf.describe().c?.[0];
	if (!isNode(opened)) throw new Error("expected the read group node first");
	expect(opened.p).toMatchObject({ collapsed: false });
	expect(nodes(opened).filter((n) => n.k === "section")).toHaveLength(2);
});

test("omp tool cards are agent nodes with sanitized omp text, live and settled", () => {
	const omp = fixtureByName("omp");
	if (!omp) throw new Error("no omp fixture");
	const running = JSON.stringify(new ToolCardComponent(fixtureBlock(omp, "running")).describe());
	expect(running).toContain('"k":"agent"');
	expect(running).toContain("Fix the flaky reconnect test");
	expect(running).toContain('"status":"running"');
	const settled = JSON.stringify(new ToolCardComponent(fixtureBlock(omp, "success")).describe());
	expect(settled).toContain('"status":"idle"');
	expect(settled).toContain("The reconnect suite passed 20 consecutive runs.");
	const hostile = JSON.stringify(
		new ToolCardComponent(
			block(
				"omp",
				{ action: "status", id: "omp_x" },
				{
					action: "status",
					session: {
						id: "omp_x",
						title: "evil\u001b]0;owned\u0007 title",
						status: "failed",
						error: "bad\u001b[2J news",
					},
				},
			),
		).describe(),
	);
	expect(hostile).not.toMatch(/\\u001b|\\u0007/);
	expect(hostile).toContain("evil title");
	expect(hostile).toContain("bad news");
});

test("native omp batch and catalog cards use bounded structured details", () => {
	const batch = JSON.stringify(
		new ToolCardComponent(
			block(
				"omp",
				{ action: "start_many" },
				{
					action: "start_many",
					sessions: [
						{ id: "omp_worker", status: "idle", lastTurn: "completed", result: "Finished" },
					],
					usage: { totalTokens: 2000, cost: 0.1 },
					errors: [{ task: 1, error: "invalid_task", message: "bad task" }],
				},
			),
		).describe(),
	);
	expect(batch).toContain("omp_worker · idle · completed · Finished");
	expect(batch).toContain("combined: 2.0k tok · $0.1000");
	expect(batch).toContain("task 2: invalid_task");
	const models = JSON.stringify(
		new ToolCardComponent(
			block(
				"omp",
				{ action: "models" },
				{
					action: "models",
					models: [{ selector: "provider/free", free: true }],
				},
			),
		).describe(),
	);
	expect(models).toContain("provider/free · ctx ? · FREE");
});
