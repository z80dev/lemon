/**
 * `bun run gallery` — every tool renderer, every lifecycle state, to stdout.
 *
 * Visual QA without a live agent: the gallery drives real
 * {@link ToolCardComponent}s from the recorded-shape fixtures in
 * `fixtures/tool-fixtures.ts`, at each requested width, and prints what the
 * transcript would show. It is headless by construction — no TTY, no TUI, no
 * terminal probing — so it runs in CI as a smoke test and under `| head`.
 *
 * Usage:
 *   bun run gallery                          every tool, every state, 80 + 120
 *   bun run gallery --tool edit              one tool
 *   bun run gallery --state error            one state (repeatable, or a,b)
 *   bun run gallery --width 100              one width (repeatable, or 80,120)
 *   bun run gallery --plain                  strip ANSI (diffable output)
 *   bun run gallery --section diff           one section: tools|diff|shelf|accordion
 *   bun run gallery --list                   fixture names and their engines
 */

import { truncateToWidth, visibleWidth } from "@oh-my-pi/pi-tui/utils";
import { AccordionComponent, type AccordionState } from "../ui/components/accordion.ts";
import { renderDiff } from "../ui/components/diff.ts";
import { ToolCardComponent } from "../ui/components/tool-card.ts";
import { ToolShelfComponent } from "../ui/components/tool-shelf.ts";
import { getTheme, initTheme } from "../ui/theme/theme.ts";
import { buildDiffText, type ToolCardState } from "../ui/tool-view.ts";
import { fixtureBlock, TOOL_FIXTURES, type ToolFixture } from "./fixtures/tool-fixtures.ts";

const STATES: ToolCardState[] = ["streaming", "running", "success", "error"];
const STATE_LABELS: Record<ToolCardState, string> = {
	streaming: "streaming args",
	running: "running",
	success: "success",
	error: "error",
};

const SECTIONS = ["tools", "diff", "shelf", "accordion"] as const;
type Section = (typeof SECTIONS)[number];

/** Fixed clock so repeated runs are byte-identical (and diffable). */
const NOW = 1_755_400_000_000;
const STARTED_AT = NOW - 2_400;

export interface GalleryOptions {
	widths: number[];
	states: ToolCardState[];
	sections: Section[];
	tool: string | undefined;
	plain: boolean;
	list: boolean;
}

const ESC = String.fromCharCode(27);
const BEL = String.fromCharCode(7);
const ANSI = new RegExp(
	`${ESC}\\[[0-9;?]*[A-Za-z]|${ESC}\\][^${BEL}${ESC}]*(?:${BEL}|${ESC}\\\\)`,
	"g",
);

function stripAnsi(text: string): string {
	return text.replace(ANSI, "");
}

export function parseGalleryArgs(argv: readonly string[]): GalleryOptions {
	const options: GalleryOptions = {
		widths: [],
		states: [],
		sections: [],
		tool: undefined,
		plain: false,
		list: false,
	};
	const values = (raw: string | undefined): string[] =>
		(raw ?? "")
			.split(",")
			.map((part) => part.trim())
			.filter((part) => part.length > 0);

	for (let i = 0; i < argv.length; i++) {
		const arg = argv[i];
		switch (arg) {
			case "--tool":
				options.tool = argv[++i];
				break;
			case "--state":
				for (const value of values(argv[++i])) {
					if (!STATES.includes(value as ToolCardState)) {
						throw new Error(`unknown --state '${value}' (want ${STATES.join(", ")})`);
					}
					options.states.push(value as ToolCardState);
				}
				break;
			case "--width":
				for (const value of values(argv[++i])) {
					const width = Number.parseInt(value, 10);
					if (!Number.isFinite(width) || width < 20) {
						throw new Error(`invalid --width '${value}' (minimum 20)`);
					}
					options.widths.push(width);
				}
				break;
			case "--section":
				for (const value of values(argv[++i])) {
					if (!SECTIONS.includes(value as Section)) {
						throw new Error(`unknown --section '${value}' (want ${SECTIONS.join(", ")})`);
					}
					options.sections.push(value as Section);
				}
				break;
			case "--plain":
				options.plain = true;
				break;
			case "--list":
				options.list = true;
				break;
			case "--help":
			case "-h":
				options.list = true;
				break;
			default:
				if (arg?.startsWith("--")) throw new Error(`unknown flag ${arg}`);
		}
	}
	if (options.widths.length === 0) options.widths = [80, 120];
	if (options.states.length === 0) options.states = [...STATES];
	if (options.sections.length === 0) {
		// `--tool` is a tool-section filter; the diff/shelf/accordion sections are
		// not per-tool, so asking for one tool means asking for that section.
		options.sections = options.tool ? ["tools"] : [...SECTIONS];
	}
	return options;
}

function rule(label: string, width: number): string[] {
	const theme = getTheme();
	const bar = theme.hrChar;
	// The label can outrun a narrow width; the rule must not.
	const head = truncateToWidth(`${bar}${bar} ${label} `, width);
	const fill = Math.max(0, width - visibleWidth(head));
	return ["", theme.fg("accent", `${head}${bar.repeat(fill)}`)];
}

function subheading(label: string, width: number): string[] {
	const theme = getTheme();
	return ["", theme.fg("dim", truncateToWidth(label, width))];
}

/** Render every requested fixture × state at one width. */
export function renderToolSection(options: GalleryOptions, width: number): string[] {
	const out: string[] = [];
	const fixtures = options.tool
		? TOOL_FIXTURES.filter((fixture) => fixture.name === options.tool)
		: TOOL_FIXTURES;
	if (fixtures.length === 0) throw new Error(`no fixture named '${options.tool}'`);

	for (const fixture of fixtures) {
		out.push(
			...rule(`${fixture.name}  (${fixture.engine}, kind=${fixture.kind}) @${width}`, width),
		);
		for (const state of options.states) {
			out.push(...subheading(`  ${STATE_LABELS[state]}`, width));
			for (const line of cardFor(fixture, state).render(width)) out.push(line);
		}
	}
	return out;
}

function cardFor(fixture: ToolFixture, state: ToolCardState): ToolCardComponent {
	return new ToolCardComponent(fixtureBlock(fixture, state, { at: STARTED_AT }), {
		now: () => NOW,
	});
}

export function renderDiffSection(width: number): string[] {
	const out: string[] = [...rule(`diff samples @${width}`, width)];
	const samples: Array<{ label: string; text: string; path?: string }> = [
		{
			label: "  single-line replacement (word-level highlight)",
			path: "lib/run.ex",
			text: buildDiffText(
				"  {:ok, pid} = Runner.start_link(job)\n  Registry.register(job.id, pid)",
				"  {:ok, pid} = Runner.start_link(job, timeout: :infinity)\n  Registry.register(job.id, pid)",
			),
		},
		{
			label: "  multi-line block replacement",
			path: "src/tool-view.ts",
			text: buildDiffText(
				"function state(block) {\n\treturn block.phase;\n}",
				"function state(block: ToolBlock): ToolCardState {\n\tif (block.phase === 'completed') return 'success';\n\treturn 'running';\n}",
			),
		},
		{
			label: "  indentation change (dim whitespace glyphs)",
			path: "src/app.ts",
			text: buildDiffText("    const x = 1;", "\tconst x = 1;"),
		},
		{
			label: "  pure insertion",
			path: "src/app.ts",
			text: buildDiffText("a\nb", "a\ninserted line\nb"),
		},
	];
	for (const sample of samples) {
		out.push(...subheading(sample.label, width));
		for (const line of renderDiff(sample.text, { path: sample.path })) {
			out.push(truncateToWidth(line, width));
		}
	}
	return out;
}

export function renderShelfSection(width: number): string[] {
	const out: string[] = [...rule(`tool shelf @${width}`, width)];
	const names = ["read", "grep", "find", "bash"];

	out.push(...subheading("  one completed tool: keeps its full card", width));
	const single = new ToolShelfComponent({ now: () => NOW });
	single.add(fixtureBlock(TOOL_FIXTURES[0] as ToolFixture, "success", { at: STARTED_AT }));
	for (const line of single.render(width)) out.push(line);

	out.push(...subheading("  a run of four: merged to one line each", width));
	const shelf = new ToolShelfComponent({ now: () => NOW });
	for (const name of names) {
		const fixture = TOOL_FIXTURES.find((item) => item.name === name);
		if (fixture) shelf.add(fixtureBlock(fixture, "success", { at: STARTED_AT }));
	}
	for (const line of shelf.render(width)) out.push(line);

	out.push(...subheading("  the tail is still running: it keeps its card", width));
	const live = new ToolShelfComponent({ now: () => NOW });
	for (const name of ["read", "grep"]) {
		const fixture = TOOL_FIXTURES.find((item) => item.name === name);
		if (fixture) live.add(fixtureBlock(fixture, "success", { at: STARTED_AT }));
	}
	const running = TOOL_FIXTURES.find((item) => item.name === "bash");
	if (running) live.add(fixtureBlock(running, "running", { at: STARTED_AT }));
	for (const line of live.render(width)) out.push(line);

	return out;
}

export function renderAccordionSection(width: number): string[] {
	const out: string[] = [...rule(`accordion @${width}`, width)];
	const theme = getTheme();
	const lines = [
		"total 96",
		"drwxr-xr-x 6 z80 z80  4096 Aug 17 00:57 .",
		"-rw-r--r-- 1 z80 z80   451 Aug 16 23:04 biome.json",
		"-rw-r--r-- 1 z80 z80  5642 Aug 16 23:04 bun.lock",
	].map((line) => theme.fg("toolDetail", line));

	for (const state of ["expanded", "collapsed", "hidden"] as AccordionState[]) {
		out.push(...subheading(`  ${state}`, width));
		const accordion = new AccordionComponent(state);
		accordion.setLines(lines);
		accordion.setSummary(lines[0] ?? "");
		const rows = accordion.render(width);
		if (rows.length === 0) out.push(theme.fg("dim", "  (no rows)"));
		for (const row of rows) out.push(row);
	}

	out.push(...subheading("  per-kind defaults: reasoning collapses, tools expand", width));
	for (const name of ["reasoning", "read"]) {
		const fixture = TOOL_FIXTURES.find((item) => item.name === name);
		if (!fixture) continue;
		for (const line of cardFor(fixture, "success").render(width)) out.push(line);
	}
	return out;
}

export function renderGallery(options: GalleryOptions): string[] {
	if (options.list) {
		return [
			`tools:    ${TOOL_FIXTURES.map((fixture) => fixture.name).join(", ")}`,
			`states:   ${STATES.join(", ")}`,
			`sections: ${SECTIONS.join(", ")}`,
			"flags:   --tool <name> --state <s,…> --width <n,…> --section <s,…> --plain --list",
		];
	}
	const out: string[] = [];
	for (const width of options.widths) {
		if (options.sections.includes("tools")) out.push(...renderToolSection(options, width));
		if (options.sections.includes("diff")) out.push(...renderDiffSection(width));
		if (options.sections.includes("shelf")) out.push(...renderShelfSection(width));
		if (options.sections.includes("accordion")) out.push(...renderAccordionSection(width));
	}
	return options.plain ? out.map(stripAnsi) : out;
}

export function runGallery(argv: readonly string[]): string[] {
	// Components take their theme by constructor argument and pi-tui ships no
	// defaults, so this must happen before anything is built.
	initTheme();
	return renderGallery(parseGalleryArgs(argv));
}

if (import.meta.main) {
	try {
		process.stdout.write(`${runGallery(process.argv.slice(2)).join("\n")}\n`);
	} catch (error) {
		process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
		process.exit(1);
	}
}
