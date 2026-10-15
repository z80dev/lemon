/**
 * Lemon tool actions as pi-tui's semantic tool views.
 *
 * omp's renderers (`@oh-my-pi/pi-tui/tools/*`) turn a call and its result into
 * a {@link NativeToolView}: a data head (title, target, meta, exit, badges)
 * over semantic body nodes (a run box, a diff, numbered code, file rows, a
 * checklist, agent rows). Tern styles those nodes by their `omp.*` roles.
 *
 * Lemon's daemon speaks a different wire shape (`detail.args`, the bounded
 * `detail.result` text, `detail.details`, `result_meta`), so each tool here is
 * either adapted into the omp renderer's inputs (bash, whose shapes genuinely
 * match) or built from the same helpers the omp renderers use (`fileRow`,
 * `nativeDiff`, `numberedCode`, `runBox`, `inlineErrorView`, …). Paths link
 * through {@link fileTarget}, so ⌘-click opens the changed line or read offset
 * exactly as the row renderer's OSC 8 links do.
 *
 * Pure: the same block and options always describe the same view.
 */

import { basename, isAbsolute, join } from "node:path";
import { nativeDiff } from "@oh-my-pi/pi-tui/chrome/diff";
import { getLanguageFromPath } from "@oh-my-pi/pi-tui/lang-from-path";
import {
	code,
	col,
	compact,
	keyed,
	md,
	node,
	row,
	span,
	text,
} from "@oh-my-pi/pi-tui/native/describe";
import type { NativeChild, NativeNode } from "@oh-my-pi/pi-tui/native/node";
import { plainText } from "@oh-my-pi/pi-tui/native/spans";
import { getDiffStats, getDomain } from "@oh-my-pi/pi-tui/render/render-utils";
import { type BashToolDetails, bashToolRenderer } from "@oh-my-pi/pi-tui/tools/bash";
import { describeDefaultToolExecution } from "@oh-my-pi/pi-tui/tools/default-renderer";
import { numberedCode } from "@oh-my-pi/pi-tui/tools/grouped-file-output";
import {
	diffStatsMeta,
	displayPath,
	errorText,
	fileDiffSection,
	fileRow,
	footnoteText,
	inlineErrorView,
	noteText,
} from "@oh-my-pi/pi-tui/tools/native-view";
import { readContentCode } from "@oh-my-pi/pi-tui/tools/read";
import type {
	NativeToolHead,
	NativeToolView,
	RenderResultOptions,
} from "@oh-my-pi/pi-tui/tools/renderer";
import { type TodoItem, todoChecklistPhases } from "@oh-my-pi/pi-tui/tools/todo";
import {
	getSearchProviderLabel,
	type SearchProviderId,
} from "@oh-my-pi/pi-tui/tools/web-search-types";
import { formatCount } from "@oh-my-pi/pi-utils";
import { safeLine, safeText } from "../formatters/base.ts";
import { ompSessionLabel, ompStatusText, ompTodoProgress } from "../formatters/omp.ts";
import { parseOmpDiscoveredList, parseOmpSession, parseOmpSessions } from "../protocol/omp.ts";
import type { ToolBlock } from "../store/transcript-model.ts";
import { ompAgentNode, ompDetailNodes } from "../ui/omp-nodes.ts";
import { type ToolView, toolArgs, toolDetails } from "../ui/tool-view.ts";
import { fileTarget, toolLocation } from "./links.ts";

/** Display state the transcript threads into a view. */
export interface NativeToolViewOptions {
	/** The card is open (not clamped to its preview); views may trim what a fold hides. */
	expanded: boolean;
	/** Milliseconds run so far (live) or in total (settled). */
	elapsedMs: number | undefined;
}

/** Everything a per-tool view reads from one block, resolved once. */
interface ToolFacts {
	readonly block: ToolBlock;
	readonly view: ToolView;
	readonly options: NativeToolViewOptions;
	readonly args: Record<string, unknown>;
	/** Structured details: the result's when settled, the latest partial's while running. */
	readonly details: Record<string, unknown>;
	readonly meta: Record<string, unknown>;
	/** Result text when settled, the latest partial text while running. */
	readonly output: string;
	readonly settled: boolean;
	readonly failed: boolean;
}

/** Files a collapsed grep shows before `N more files` (omp §7.3 grep). */
const COLLAPSED_GREP_FILES = 2;
/** Collapsed clamp of search and listing bodies. */
const SEARCH_PREVIEW = { lines: 20 } as const;
/** Most files listed as rows; more wrap as chips (omp §7.3 glob). */
const FILE_ROWS_MAX = 6;
/** Collapsed clamp of a file listing: the whole ≤ 6-row list, or a few rows of chips. */
const FILE_LIST_PREVIEW = { lines: 8 } as const;
/** Collapsed clamp of a written file's source. */
const WRITE_PREVIEW = { lines: 8 } as const;
/** Collapsed clamp of a fetched page. */
const FETCH_PREVIEW = { lines: 12 } as const;

// -- small readers -------------------------------------------------------------

function str(value: unknown): string | undefined {
	return typeof value === "string" && value.length > 0 ? value : undefined;
}

function num(value: unknown): number | undefined {
	return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function record(value: unknown): Record<string, unknown> | undefined {
	return value && typeof value === "object" && !Array.isArray(value)
		? (value as Record<string, unknown>)
		: undefined;
}

function contentText(value: unknown): string | undefined {
	const content = record(value)?.content;
	if (!Array.isArray(content)) return undefined;
	const parts: string[] = [];
	for (const item of content) {
		const part = record(item);
		if (part?.type === "text" && typeof part.text === "string") parts.push(part.text);
	}
	return parts.length > 0 ? parts.join("\n") : undefined;
}

function facts(block: ToolBlock, view: ToolView, options: NativeToolViewOptions): ToolFacts {
	const detail = block.detail ?? {};
	const settled = block.phase === "completed";
	const partial = settled ? undefined : record(detail.partial_result);
	const details = settled ? toolDetails(block) : (record(partial?.details) ?? {});
	const output = settled
		? (str(detail.result) ?? "")
		: (contentText(partial) ??
			(typeof detail.partial_result === "string" ? detail.partial_result : ""));
	return {
		block,
		view,
		options,
		args: toolArgs(block),
		details,
		meta: record(detail.result_meta) ?? {},
		output,
		settled,
		failed: view.state === "error",
	};
}

/** The failure text: the result, the error metadata, then the event's own message. */
function failureMessage(f: ToolFacts): string {
	return (
		str(f.output.trim()) ??
		str(f.meta.message) ??
		str(f.meta.reason) ??
		str(f.block.message) ??
		str(f.view.summary) ??
		"failed"
	).replace(/^Error:\s*/, "");
}

/** `browser_navigate` → `Browser navigate`: a head verb for tools omp has no renderer for. */
function toolLabel(name: string): string {
	const words = name.replace(/[_-]+/g, " ").trim();
	return words ? words[0]!.toUpperCase() + words.slice(1) : name;
}

/** The Lemon file location a head links to (changed line, read offset), as a `file://` URL. */
function locationHref(block: ToolBlock): string | undefined {
	const location = toolLocation(block);
	return location ? fileTarget(location.path, location.line) : undefined;
}

/** A diff body from renderDiff-form rows (`±N|content`, or `±content` without numbers). */
export function diffNode(rows: string, path: string | undefined): NativeNode {
	const lang = path ? getLanguageFromPath(path) : undefined;
	const lines = rows.split("\n").filter((line) => line.length > 0);
	// Numbered rows carry real file positions; pi-tui's parser rebuilds hunks from them.
	if (lines.every((line) => /^[+\- ]\s*\d+\|/.test(line) || /^\s*(\.\.\.|…)\s*$/.test(line))) {
		return nativeDiff(rows, { lang });
	}
	return diffFromHunks(splitHunks(lines), lang);
}

/** Unnumbered rows as hunks, split at `...`/`@@` separators (no positions are claimed beyond line 1). */
function splitHunks(lines: readonly string[]): string[][] {
	const hunks: string[][] = [];
	let current: string[] = [];
	for (const line of lines) {
		if (/^\s*(\.\.\.|…)\s*$/.test(line) || line.startsWith("@@")) {
			if (current.length > 0) hunks.push(current);
			current = [];
			continue;
		}
		const prefix = line[0];
		current.push(prefix === "+" || prefix === "-" ? line : ` ${line.slice(1)}`);
	}
	if (current.length > 0) hunks.push(current);
	return hunks;
}

function diffFromHunks(hunks: readonly string[][], lang: string | undefined): NativeNode {
	return node("diff", {
		hunks: hunks.map((lines) => ({ oldStart: 1, newStart: 1, lines })),
		lang,
	});
}

/** Strip the daemon's untrusted-content envelope from web text (the model needs it; a reader does not). */
function unwrapExternal(value: unknown): string {
	if (typeof value !== "string") return "";
	const start = value.indexOf("<<<EXTERNAL_UNTRUSTED_CONTENT>>>");
	if (start < 0) return value.trim();
	let body = value.slice(start + "<<<EXTERNAL_UNTRUSTED_CONTENT>>>".length);
	const separator = body.indexOf("\n---\n");
	if (separator >= 0) body = body.slice(separator + "\n---\n".length);
	const end = body.lastIndexOf("<<<END_EXTERNAL_UNTRUSTED_CONTENT>>>");
	if (end >= 0) body = body.slice(0, end);
	return body.trim();
}

// -- entry point ---------------------------------------------------------------

/** The omp role suffix (`omp.tool.<name>`) a Lemon tool's card takes: the omp tool it mirrors. */
export function nativeToolRole(view: ToolView): string {
	const name = view.toolName;
	if (!name) return view.kind === "subagent" ? "task" : view.kind;
	switch (name) {
		case "anchored_edit":
		case "patch":
			return "edit";
		case "find":
			return "glob";
		case "websearch":
			return "web_search";
		case "webfetch":
			return "fetch";
		case "todowrite":
		case "todoread":
			return "todo";
		case "agent":
			return "task";
		default:
			return name;
	}
}

/** Lemon's view of one tool action, as omp's semantic tool view. */
export function nativeToolView(
	block: ToolBlock,
	view: ToolView,
	options: NativeToolViewOptions,
): NativeToolView {
	if (view.state === "streaming") return { tool: { title: view.title } };
	const f = facts(block, view, options);
	if (view.kind === "note" || !view.toolName) return noteView(f);
	switch (view.toolName) {
		case "bash":
			return bashView(f);
		case "read":
			return readView(f);
		case "edit":
		case "anchored_edit":
			return editView(f);
		case "patch":
			return patchView(f);
		case "write":
			return writeView(f);
		case "grep":
			return grepView(f);
		case "find":
			return findView(f);
		case "ls":
			return lsView(f);
		case "websearch":
			return searchView(f);
		case "webfetch":
			return fetchView(f);
		case "todo":
		case "todowrite":
		case "todoread":
			return todoView(f);
		case "task":
		case "agent":
			return taskView(f);
		case "omp":
			return ompView(f);
		default:
			return defaultView(f, view.toolName);
	}
}

// -- notes and unknown tools -----------------------------------------------------

function noteView(f: ToolFacts): NativeToolView {
	const summary = f.view.summary;
	const lines = f.view.body.filter((line) => line !== summary);
	return {
		tool: { title: f.view.title, meta: summary ? [summary] : undefined },
		tone: f.failed ? "error" : undefined,
		body: lines.length > 0 ? [noteText(lines.join("\n"), f.failed ? "error" : "muted")] : undefined,
	};
}

function defaultView(f: ToolFacts, name: string): NativeToolView {
	const options: RenderResultOptions = {
		expanded: f.options.expanded,
		isPartial: !f.settled,
		elapsedMs: f.options.elapsedMs,
	};
	const output = f.failed ? failureMessage(f) : f.output;
	const result =
		f.settled || output
			? { output, isError: f.failed, skipped: f.view.state === "cancelled" }
			: undefined;
	return describeDefaultToolExecution({ label: toolLabel(name), args: f.args, result, options });
}

// -- bash ----------------------------------------------------------------------

/** Remove the daemon's model-facing notices; the run foot shows the exit, timeout and cancellation. */
function stripBashNotices(output: string): string {
	return output
		.replace(/^Command cancelled\.(\n\n)?/, "")
		.replace(/(\n\n)?Command exited with code -?\d+\s*$/, "")
		.replace(/(\n\n)?Command timed out after \d+ ms and was killed\.[^\n]*\s*$/, "");
}

function bashView(f: ToolFacts): NativeToolView {
	const args = { command: str(f.args.command), cwd: str(f.args.cwd) };
	const cancelled = f.view.state === "cancelled" || f.view.state === "unknown";
	const options: RenderResultOptions = {
		expanded: f.options.expanded,
		isPartial: !f.settled,
		executionStarted: true,
		elapsedMs: f.options.elapsedMs,
		cancelled,
	};
	if (!f.settled && f.output.length === 0) return bashToolRenderer.describeCall!(args, options);
	const exitCode = num(f.details.exit_code) ?? num(f.meta.exit_code);
	const processId = str(f.details.process_id);
	const details: BashToolDetails = {
		exitCode: exitCode ?? undefined,
		timedOut: f.details.timed_out === true ? true : undefined,
		async:
			processId && f.details.status === "running"
				? { state: "running", jobId: processId, type: "bash" }
				: undefined,
	};
	const output = stripBashNotices(f.output);
	return bashToolRenderer.describeResult!(
		{ content: output ? [{ type: "text", text: output }] : [], details, isError: f.failed },
		options,
		args,
	);
}

// -- read ----------------------------------------------------------------------

/** One parsed read row: the daemon numbers each line `N: text` (older servers `N\ttext`). */
const READ_ROW = /^\s*(\d+)(?::\s|\t)(.*)$/;
/** The daemon's anchored-edit snapshot tag heading a read: `[path#abc123]`. */
const READ_SNAPSHOT = /^\[[^\]\n]+#[^\]\n]+\]$/;
/** The truncation trailer: `[Showing lines 1-200 of 982. Use offset=201 to continue.]`. */
const READ_TRAILER = /^\[Showing lines [^\]]*\]$/;

interface ParsedRead {
	text: string;
	numbers: number[] | undefined;
	trailer: string | undefined;
}

function parseRead(output: string): ParsedRead {
	const lines = output.split("\n");
	if (lines[0] !== undefined && READ_SNAPSHOT.test(lines[0])) lines.shift();
	let trailer: string | undefined;
	const last = lines.at(-1);
	if (last !== undefined && READ_TRAILER.test(last.trim())) {
		trailer = last.trim().slice(1, -1);
		lines.pop();
	}
	const rows = lines.map((line) => READ_ROW.exec(line));
	if (rows.length > 0 && rows.every((match) => match !== null)) {
		return {
			text: rows.map((match) => match![2]!).join("\n"),
			numbers: rows.map((match) => Number(match![1])),
			trailer,
		};
	}
	return { text: lines.join("\n"), numbers: undefined, trailer };
}

function readHead(f: ToolFacts, path: string | undefined): NativeToolHead {
	const start = num(f.details.start_line) ?? num(f.args.offset);
	const shown = num(f.details.lines_shown);
	const total = num(f.details.total_lines);
	const limit = num(f.args.limit);
	let range = "";
	if (start !== undefined && shown !== undefined && total !== undefined) {
		if (start > 1 || shown < total) range = `:${start}-${start + Math.max(shown, 1) - 1}`;
	} else if (start !== undefined || limit !== undefined) {
		const from = start ?? 1;
		range = `:${from}${limit !== undefined ? `-${from + limit - 1}` : ""}`;
	}
	return {
		title: "Read",
		target: path ? `${displayPath(path)}${range}` : "…",
		targetKind: "path",
		href: locationHref(f.block),
		meta: total !== undefined && range ? [formatCount("line", total)] : undefined,
	};
}

function readView(f: ToolFacts): NativeToolView {
	const path = str(f.details.path) ?? str(f.args.path) ?? str(f.args.file_path);
	const head = readHead(f, path);
	if (f.failed) return inlineErrorView(head, failureMessage(f));
	if (!f.settled || !f.output) return { tool: head, inline: true };
	const parsed = parseRead(f.output);
	const start = parsed.numbers?.[0] ?? num(f.details.start_line) ?? num(f.args.offset) ?? 1;
	const lang = path ? getLanguageFromPath(path) : undefined;
	return {
		tool: head,
		inline: true,
		body: compact<NativeChild>([
			...readContentCode(parsed.text, start, parsed.numbers, lang),
			footnoteText(compact([parsed.trailer])),
		]),
	};
}

// -- edit / write / patch --------------------------------------------------------

function editView(f: ToolFacts): NativeToolView {
	const location = toolLocation(f.block);
	const path = location?.path ?? str(f.args.path) ?? str(f.args.file_path);
	const rows = f.view.diff?.text;
	const stats = rows ? getDiffStats(rows) : undefined;
	const line = f.settled ? num(f.details.first_changed_line) : undefined;
	const head: NativeToolHead = {
		title: "Edit",
		target: path ? `${displayPath(path)}${line ? `:${line}` : ""}` : undefined,
		targetKind: "path",
		href: locationHref(f.block),
		meta: compact([stats && diffStatsMeta(stats.added, stats.removed)]),
	};
	if (f.failed) return { tool: head, tone: "error", body: [errorText(failureMessage(f))] };
	const body: NativeChild[] = [];
	if (rows) body.push(diffNode(rows, path));
	else if (f.settled)
		body.push(noteText(`No changes were made${path ? ` to ${displayPath(path)}` : ""}.`));
	return { tool: head, body };
}

function writeView(f: ToolFacts): NativeToolView {
	const path = str(f.details.path) ?? str(f.args.path) ?? str(f.args.file_path);
	const content = typeof f.args.content === "string" ? f.args.content.replace(/\r\n/g, "\n") : "";
	const lines = content ? content.replace(/\n$/, "").split("\n").length : 0;
	const head: NativeToolHead = {
		title: "Write",
		target: path ? displayPath(path) : undefined,
		targetKind: "path",
		href: locationHref(f.block),
		meta: lines > 0 ? [formatCount("line", lines)] : undefined,
		badges:
			f.settled && !f.failed && f.details.oldText === null ? [{ text: "new file" }] : undefined,
	};
	if (f.failed) return { tool: head, tone: "error", body: [errorText(failureMessage(f))] };
	if (!content) return { tool: head };
	const lang = path ? getLanguageFromPath(path) : undefined;
	return {
		tool: head,
		body: [keyed(code(content.replace(/\n$/, ""), { lang, numbers: true }), "source")],
		preview: WRITE_PREVIEW,
	};
}

interface PatchFile {
	path: string;
	op: "update" | "add" | "delete";
	rename?: string;
	hunks: string[][];
	added: number;
	removed: number;
}

/** Split a patch (`*** Update File:` envelopes or unified `--- / +++` headers) into per-file hunks. */
export function parsePatchFiles(patch: string): PatchFile[] {
	const files: PatchFile[] = [];
	let file: PatchFile | undefined;
	let hunk: string[] = [];
	const closeHunk = () => {
		if (file && hunk.length > 0) file.hunks.push(hunk);
		hunk = [];
	};
	const open = (path: string, op: PatchFile["op"]) => {
		closeHunk();
		file = { path, op, hunks: [], added: 0, removed: 0 };
		files.push(file);
	};
	for (const line of patch.replace(/\r\n/g, "\n").split("\n")) {
		const envelope = /^\*\*\* (Update|Add|Delete) File: (.+)$/.exec(line);
		if (envelope) {
			open(
				envelope[2]!.trim(),
				envelope[1] === "Add" ? "add" : envelope[1] === "Delete" ? "delete" : "update",
			);
			continue;
		}
		const move = /^\*\*\* Move to: (.+)$/.exec(line);
		if (move && file) {
			file.rename = move[1]!.trim();
			continue;
		}
		const unified = /^\+\+\+ (?:b\/)?(.+)$/.exec(line);
		if (unified && unified[1] !== "/dev/null") {
			open(unified[1]!.trim(), "update");
			continue;
		}
		if (/^(\*\*\* |diff --git |index |--- |\+\+\+ |new file mode|deleted file mode)/.test(line))
			continue;
		if (line.startsWith("@@")) {
			closeHunk();
			continue;
		}
		if (!file) continue;
		if (line.startsWith("+")) file.added++;
		else if (line.startsWith("-")) file.removed++;
		else if (line.length === 0 || line === "\\ No newline at end of file") continue;
		hunk.push(line.startsWith("+") || line.startsWith("-") ? line : ` ${line.slice(1)}`);
	}
	closeHunk();
	return files;
}

function patchView(f: ToolFacts): NativeToolView {
	const patch = str(f.args.patch_text) ?? str(f.args.patch) ?? "";
	const files = parsePatchFiles(patch);
	const changed = Array.isArray(f.details.changed)
		? f.details.changed.filter((path): path is string => typeof path === "string")
		: [];
	const count = Math.max(files.length, changed.length);
	const added = num(f.details.additions) ?? files.reduce((sum, file) => sum + file.added, 0);
	const removed = num(f.details.removals) ?? files.reduce((sum, file) => sum + file.removed, 0);
	// Like the row renderer's link, the head targets the first surviving changed file.
	const target =
		toolLocation(f.block)?.path ?? files.find((file) => file.op !== "delete")?.path ?? changed[0];
	const head: NativeToolHead = {
		title: "Patch",
		target: target ? displayPath(target) : undefined,
		targetKind: "path",
		href: locationHref(f.block),
		meta: compact([count > 1 && `+${count - 1} more`, diffStatsMeta(added, removed)]),
	};
	if (f.failed) return { tool: head, tone: "error", body: [errorText(failureMessage(f))] };
	const fileBody = (file: PatchFile): NativeChild =>
		file.op === "delete" && file.hunks.length === 0
			? noteText("Deleted")
			: diffFromHunks(file.hunks, getLanguageFromPath(file.path));
	if (files.length === 1) return { tool: head, body: [fileBody(files[0]!)] };
	return {
		tool: head,
		body: files.map((file) =>
			fileDiffSection(
				{ path: file.path, rename: file.rename, added: file.added, removed: file.removed },
				[fileBody(file)],
				{ role: "omp.tool.edit.file" },
			),
		),
	};
}

// -- grep / find / ls -------------------------------------------------------------

interface GrepLine {
	n: number;
	text: string;
	mark: boolean;
}

/** One match (`path:12: text`) or context (`path-12- text`) row of the daemon's grep output. */
const GREP_MATCH = /^(.+?):(\d+): ?(.*)$/;
const GREP_CONTEXT = /^(.+?)-(\d+)- ?(.*)$/;

function parseGrep(output: string): { files: Map<string, Map<number, GrepLine>>; notes: string[] } {
	const files = new Map<string, Map<number, GrepLine>>();
	const notes: string[] = [];
	const body = output.replace(/^Found \d+ match(?:es)?\.\s*/, "");
	for (const line of body.split("\n")) {
		if (!line.trim()) continue;
		const match = GREP_MATCH.exec(line);
		const context = match ? null : GREP_CONTEXT.exec(line);
		const parsed = match ?? context;
		if (!parsed) {
			notes.push(line.replace(/^\[|\]$/g, ""));
			continue;
		}
		const path = parsed[1]!;
		const n = Number(parsed[2]);
		let lines = files.get(path);
		if (!lines) {
			lines = new Map();
			files.set(path, lines);
		}
		const existing = lines.get(n);
		lines.set(n, { n, text: parsed[3]!, mark: Boolean(match) || existing?.mark === true });
	}
	return { files, notes };
}

/** Where a grep display path lives: the daemon prints it relative to the searched directory. */
function grepFilePath(display: string, scope: string | undefined, fileCount: number): string {
	if (!scope) return display;
	if (fileCount === 1 && basename(scope) === display) return scope;
	return isAbsolute(display) ? display : join(scope, display);
}

function grepHead(f: ToolFacts, meta: readonly string[] | undefined): NativeToolHead {
	const scope = str(f.args.path);
	const parts = meta ? [...meta] : [];
	if (!meta) {
		if (str(f.args.glob)) parts.push(String(f.args.glob));
		if (f.args.case_sensitive === false) parts.push("case:insensitive");
		if (f.args.literal === true) parts.push("literal");
	}
	if (scope) parts.push(`in ${displayPath(scope)}`);
	return { title: "Grep", target: str(f.args.pattern) ?? "?", targetKind: "pattern", meta: parts };
}

function grepView(f: ToolFacts): NativeToolView {
	if (f.failed) return inlineErrorView(grepHead(f, undefined), failureMessage(f));
	if (!f.settled) return { tool: grepHead(f, undefined), inline: true };
	const { files, notes } = parseGrep(f.output);
	const matches =
		num(f.details.match_count) ??
		[...files.values()].reduce(
			(sum, lines) => sum + [...lines.values()].filter((line) => line.mark).length,
			0,
		);
	if (matches === 0) return { tool: grepHead(f, ["0 matches"]), tone: "warning", inline: true };
	if (files.size === 0) {
		return {
			tool: grepHead(f, [formatCount("match", matches)]),
			inline: true,
			body: [code(f.output.trim())],
			preview: SEARCH_PREVIEW,
		};
	}
	const scope = str(f.args.path);
	const sections: NativeNode[] = [];
	for (const [display, lines] of files) {
		const sorted = [...lines.values()].sort((a, b) => a.n - b.n);
		const marks = sorted.filter((line) => line.mark).length;
		const resolved = grepFilePath(display, scope, files.size);
		const firstMatch = sorted.find((line) => line.mark)?.n;
		sections.push(
			keyed(
				col(
					[
						fileRow(display, {
							chip: { text: String(marks), title: formatCount("match", marks) },
							href: fileTarget(resolved, firstMatch),
							key: "file",
						}),
						...numberedCode(sorted, { lang: getLanguageFromPath(display) }),
					],
					{ gap: "xs", role: "omp.tool.search.file" },
				),
				`f:${display}`,
			),
		);
	}
	const hidden = f.options.expanded ? 0 : Math.max(0, sections.length - COLLAPSED_GREP_FILES);
	const head = grepHead(f, [
		`${formatCount("match", matches)} · ${formatCount("file", files.size)}`,
	]);
	return {
		tool:
			f.details.truncated === true
				? { ...head, badges: [{ text: "truncated", tone: "warning" }] }
				: head,
		inline: true,
		body: compact<NativeChild>([
			...sections.slice(0, sections.length - hidden),
			footnoteText(compact([hidden > 0 && formatCount("more file", hidden), ...notes])),
		]),
		preview: SEARCH_PREVIEW,
	};
}

interface ListedFile {
	path: string;
	href: string | undefined;
	detail?: string;
}

/** Files as 22px rows when there are few, else a wrap of chips (omp §7.3 glob). */
function fileList(files: readonly ListedFile[]): NativeNode {
	if (files.length <= FILE_ROWS_MAX) {
		return col(
			files.map((file) => fileRow(file.path, { href: file.href, detail: file.detail })),
			{ role: "omp.tool.files", gap: "none" },
		);
	}
	return row(
		files.map((file) => {
			const isDir = file.path.endsWith("/");
			const name = basename(file.path) + (isDir ? "/" : "");
			return keyed(
				row(
					[
						node("icon", { name: isDir ? "folder" : "file" }),
						text([span(name, "strong", file.href ? { href: file.href } : undefined)], {
							wrap: "none",
						}),
					],
					{ role: "omp.tool.chip", gap: "xs", align: "center", title: file.path },
				),
				file.path,
			);
		}),
		{ role: "omp.tool.files", gap: "xs", wrap: true },
	);
}

function findHead(f: ToolFacts, meta: readonly string[]): NativeToolHead {
	const scope = str(f.args.path);
	const parts = [...meta];
	if (scope) parts.push(`in ${displayPath(scope)}`);
	return { title: "Find", target: str(f.args.pattern) ?? "*", targetKind: "pattern", meta: parts };
}

function findView(f: ToolFacts): NativeToolView {
	if (f.failed) return inlineErrorView(findHead(f, []), failureMessage(f));
	if (!f.settled) {
		const type = str(f.args.type);
		return { tool: findHead(f, type && type !== "all" ? [`type:${type}`] : []), inline: true };
	}
	const listed = Array.isArray(f.details.files)
		? f.details.files.filter((file): file is string => typeof file === "string")
		: f.output
				.replace(/^Found [^\n]*:\n\n/, "")
				.split("\n")
				.filter((line) => line.trim() && !line.startsWith("No files found"));
	if (listed.length === 0) return { tool: findHead(f, ["0 files"]), tone: "warning", inline: true };
	const head = findHead(f, [formatCount("file", listed.length)]);
	return {
		tool:
			f.details.truncated === true
				? { ...head, badges: [{ text: "truncated", tone: "warning" }] }
				: head,
		inline: true,
		body: [fileList(listed.map((path) => ({ path, href: fileTarget(path) })))],
		preview: FILE_LIST_PREVIEW,
	};
}

/** `d name` (short) or `d drwxr-xr-x     4.0K 2026-01-02 03:04 name` (long) listing rows. */
const LS_LONG = /^(\S) \S{9,10} +(\S+) (\d{4}-\d\d-\d\d \d\d:\d\d|\s*\?) (.+)$/;
const LS_SHORT = /^(\S) (.+)$/;

function lsView(f: ToolFacts): NativeToolView {
	const dir = str(f.details.path) ?? str(f.args.path) ?? ".";
	const shownDir = str(f.args.path) ?? dir;
	const total = num(f.details.total_entries);
	const head: NativeToolHead = {
		title: "List",
		target: displayPath(shownDir),
		targetKind: "path",
		href: fileTarget(dir),
		meta: f.settled && total !== undefined ? [formatCount("entry", total)] : undefined,
		badges: f.details.truncated === true ? [{ text: "truncated", tone: "warning" }] : undefined,
	};
	if (f.failed) return inlineErrorView(head, failureMessage(f));
	if (!f.settled) return { tool: head, inline: true };
	const files: ListedFile[] = [];
	let footer: string | undefined;
	for (const line of f.output.split("\n")) {
		if (!line.trim() || line.startsWith("Directory: ") || /^\d+ entries$/.test(line)) continue;
		if (line.startsWith("[") || line === "(empty directory)") {
			footer = line.replace(/^\[|\]$/g, "");
			continue;
		}
		const long = LS_LONG.exec(line);
		const short = long ? null : LS_SHORT.exec(line);
		const kind = (long ?? short)?.[1];
		const name = long ? long[4]! : short ? short[2]! : line;
		const path = kind === "d" && !name.endsWith("/") ? `${name}/` : name;
		files.push({
			path,
			href: kind === "d" ? undefined : fileTarget(isAbsolute(name) ? name : join(dir, name)),
			detail: long ? `${long[2]} · ${long[3]!.trim()}` : undefined,
		});
	}
	if (files.length === 0) {
		return {
			tool: head,
			tone: "warning",
			inline: true,
			body: [noteText(footer ?? "(empty directory)")],
		};
	}
	return {
		tool: head,
		inline: true,
		body: compact<NativeChild>([fileList(files), footer ? footnoteText([footer]) : undefined]),
		preview: SEARCH_PREVIEW,
	};
}

// -- web -------------------------------------------------------------------------

function providerLabel(id: unknown): string | undefined {
	const raw = str(id);
	if (!raw) return undefined;
	const key = raw.replace(/_/g, "").toLowerCase() as SearchProviderId;
	const label = getSearchProviderLabel(key);
	return label === key ? raw : label;
}

/** One cited source: domain-initial mark, linked title, muted `domain · age` (omp `omp.tool.source`). */
function sourceRow(source: Record<string, unknown>, index: number): NativeNode {
	const url = str(source.url) ?? "";
	const title = unwrapExternal(source.title) || url || "Untitled";
	const domain = str(source.site_name) ?? (url ? getDomain(url) : "");
	const age = str(source.published) ?? "";
	const meta = [domain, age].filter(Boolean).join(" · ");
	const snippet = unwrapExternal(source.description);
	const initial = (domain.replace(/^www\./, "")[0] ?? "?").toUpperCase();
	return node(
		"row",
		{ gap: "sm", align: "baseline", role: "omp.tool.source", href: url || undefined },
		compact([
			node("badge", { text: initial, title: domain || undefined }),
			text([span(plainText(title), "link", url ? { href: url } : undefined)], {
				lines: 1,
				truncate: "end",
				title: snippet ? plainText(snippet) : undefined,
			}),
			meta ? text([span(plainText(meta), "muted")], { lines: 1 }) : undefined,
		]),
		`${index}:${url}`,
	);
}

function searchView(f: ToolFacts): NativeToolView {
	const query = str(f.args.query);
	const head = (meta?: string): NativeToolHead => ({
		title: "Web search",
		target: query ? plainText(query) : undefined,
		targetKind: "query",
		meta: meta ? [meta] : undefined,
	});
	if (f.failed) return { tool: head(), tone: "error", body: [errorText(failureMessage(f))] };
	if (!f.settled) return { tool: head(), inline: true };
	const results = Array.isArray(f.details.results)
		? f.details.results.map(record).filter((r) => r !== undefined)
		: [];
	const citations = Array.isArray(f.details.citations)
		? f.details.citations
				.map((url) => (typeof url === "string" ? { url } : record(url)))
				.filter((r) => r !== undefined)
		: [];
	const sources = results.length > 0 ? results : citations;
	const answer = unwrapExternal(f.details.content);
	const provider = providerLabel(f.details.provider);
	const meta = [provider, formatCount("source", sources.length)].filter(Boolean).join(" · ");
	if (sources.length === 0 && !answer) {
		// No structured payload: show what the daemon said rather than a raw JSON blob.
		const raw = f.output.trim();
		return {
			tool: head(meta),
			tone: "warning",
			body: [noteText(raw.startsWith("{") ? "No results" : raw || "No results")],
		};
	}
	return {
		tool: f.details.cached === true ? { ...head(meta), badges: [{ text: "cached" }] } : head(meta),
		tone: sources.length > 0 ? undefined : "warning",
		body: compact<NativeChild>([
			answer ? keyed(md(plainText(answer)), "answer") : undefined,
			sources.length > 0 &&
				node("col", { role: "omp.tool.sources" }, sources.map(sourceRow), "sources"),
		]),
	};
}

function fetchView(f: ToolFacts): NativeToolView {
	const url = str(f.args.url);
	const finalUrl = str(f.details.finalUrl) ?? url;
	const status = num(f.details.status);
	const contentType = str(f.details.contentType)?.split(";")[0];
	const head: NativeToolHead = {
		title: "Fetch",
		target: url,
		targetKind: "text",
		href: finalUrl && /^https?:\/\//i.test(finalUrl) ? finalUrl : undefined,
		meta: compact([
			status !== undefined && status !== 200 && `HTTP ${status}`,
			contentType,
			finalUrl && url && finalUrl !== url && `→ ${getDomain(finalUrl)}`,
		]),
		badges: f.details.truncated === true ? [{ text: "truncated", tone: "warning" }] : undefined,
	};
	if (f.failed) return inlineErrorView(head, failureMessage(f));
	if (!f.settled) return { tool: head, inline: true };
	const body = unwrapExternal(f.details.text) || unwrapExternal(f.output);
	if (!body) return { tool: head, inline: true };
	const title = unwrapExternal(f.details.title);
	const markdown = str(f.details.extractMode) !== "text";
	return {
		tool: title ? { ...head, meta: [...(head.meta ?? []), title] } : head,
		body: [keyed(markdown ? md(body) : text(body, { wrap: "word" }), "page")],
		preview: FETCH_PREVIEW,
	};
}

// -- todo ------------------------------------------------------------------------

const TODO_STATUS: Record<string, TodoItem["status"]> = {
	pending: "pending",
	in_progress: "in_progress",
	completed: "completed",
	blocked: "blocked",
	cancelled: "abandoned",
	abandoned: "abandoned",
};

function todoItems(value: unknown): TodoItem[] {
	if (!Array.isArray(value)) return [];
	const items: TodoItem[] = [];
	for (const entry of value) {
		const todo = record(entry);
		const content = str(todo?.content);
		if (!todo || !content) continue;
		items.push({ content, status: TODO_STATUS[String(todo.status)] ?? "pending" });
	}
	return items;
}

function todoView(f: ToolFacts): NativeToolView {
	const action = str(f.args.action);
	const verb = action && action !== "write" ? action : undefined;
	if (f.failed) {
		return {
			tool: { title: "Todo", target: verb, targetKind: verb ? "text" : undefined },
			tone: "error",
			body: [errorText(failureMessage(f))],
		};
	}
	const items = todoItems(Array.isArray(f.details.todos) ? f.details.todos : f.args.todos);
	if (items.length === 0) {
		return {
			tool: {
				title: "Todo",
				target: verb ?? (f.settled ? undefined : "update"),
				targetKind: "text",
			},
			body: f.settled ? [noteText("No todos")] : undefined,
		};
	}
	const closed = items.filter(
		(item) => item.status === "completed" || item.status === "abandoned",
	).length;
	return {
		tool: {
			title: "Todo",
			target: `${closed}/${items.length}`,
			targetKind: "text",
			meta: verb ? [verb] : undefined,
		},
		body: [
			node(
				"checklist",
				// Lemon todos have no phases; a titled phase would repeat the head's count.
				{ mode: "full", phases: todoChecklistPhases([{ name: "", tasks: items }]) },
				[],
				"checklist",
			),
		],
		preview: "none",
		open: true,
	};
}

// -- task / agent ------------------------------------------------------------------

/** The `agent` kind's status vocabulary (TSP §7.6). */
type AgentStatus = "pending" | "running" | "done" | "failed" | "aborted" | "idle" | "parked";

const AGENT_STATUS: Record<string, AgentStatus> = {
	queued: "pending",
	pending: "pending",
	running: "running",
	completed: "done",
	done: "done",
	error: "failed",
	failed: "failed",
	cancelled: "aborted",
	aborted: "aborted",
	needs_parent_answer: "parked",
};

/** One-line assignment summary: the description, else the prompt's first line. */
function taskSummary(value: unknown): string | undefined {
	const line = str(value)
		?.split("\n")
		.find((part) => part.trim());
	return line ? plainText(line.trim()) : undefined;
}

function taskStatus(f: ToolFacts, details: Record<string, unknown>): AgentStatus {
	const raw = str(details.status);
	if (raw && AGENT_STATUS[raw]) return AGENT_STATUS[raw];
	if (f.failed)
		return details.error_type === "aborted" || f.meta.error_type === "aborted"
			? "aborted"
			: "failed";
	if (f.view.state === "cancelled" || f.view.state === "unknown") return "aborted";
	return f.settled ? "done" : "running";
}

function agentNodeFor(
	f: ToolFacts,
	details: Record<string, unknown>,
	p: { key: string; prompt?: string; output?: string; error?: string; elapsed?: number },
): NativeNode {
	const status = taskStatus(f, details);
	const running = status === "running" || status === "pending";
	const action = record(details.current_action);
	const role = str(details.agent) ?? str(details.role) ?? str(f.args.agent);
	const name =
		str(details.name) ?? str(f.args.name) ?? str(details.task_id) ?? str(f.args.task_id) ?? "agent";
	const background = f.args.async === true || details.status === "queued";
	return node(
		"agent",
		{
			name: plainText(name),
			agent: role && role !== "task" ? plainText(role) : undefined,
			task:
				taskSummary(details.description) ??
				taskSummary(f.args.description) ??
				taskSummary(p.prompt),
			status,
			model: str(f.args.model),
			tool:
				running && action
					? { name: plainText(str(action.title) ?? str(action.kind) ?? "tool") }
					: null,
			stats:
				p.elapsed === undefined ? undefined : running ? { age: p.elapsed } : { took: p.elapsed },
			badges: background ? [{ text: "background" }] : undefined,
			collapsible: true,
			collapsed: !f.options.expanded,
		},
		compact<NativeChild>([
			p.prompt ? md(p.prompt.trim(), { role: "omp.task.assignment" }) : undefined,
			p.error
				? text([span(plainText(p.error), "error")], { wrap: "word", role: "omp.tool.error" })
				: undefined,
			p.output ? md(p.output.trim(), { role: "omp.task.output" }) : undefined,
		]),
		p.key,
	);
}

function taskView(f: ToolFacts): NativeToolView {
	const action = str(f.args.action) ?? "run";
	const ids = Array.isArray(f.args.task_ids)
		? f.args.task_ids.filter((id): id is string => typeof id === "string")
		: [];
	const joined = (
		Array.isArray(f.details.tasks)
			? f.details.tasks
			: Array.isArray(f.details.results)
				? f.details.results
				: []
	)
		.map(record)
		.filter((entry) => entry !== undefined);
	const description = taskSummary(f.details.description) ?? taskSummary(f.args.description);
	const target =
		joined.length > 1
			? formatCount("agent", joined.length)
			: (description ?? str(f.args.task_id) ?? (ids.length > 0 ? ids.join(", ") : undefined));
	const background = f.args.async === true || f.details.status === "queued";
	const head: NativeToolHead = {
		title: f.view.toolName === "agent" ? "Agent" : "Task",
		target,
		targetKind: target ? "text" : undefined,
		meta: action !== "run" ? [action] : undefined,
		badges: background ? [{ text: "background" }] : undefined,
	};
	const prompt = str(f.args.prompt) ?? str(f.args.message);
	const ok = f.view.state === "success";
	const error = ok ? str(f.details.error) : f.settled ? failureMessage(f) : undefined;
	let agents: NativeNode[];
	if (joined.length > 0) {
		agents = joined.map((entry, index) =>
			agentNodeFor(f, entry, {
				key: str(entry.task_id) ?? String(index),
				output: str(entry.result) ?? str(entry.output),
				error: str(entry.error),
			}),
		);
	} else if (action === "run" || f.view.toolName === "agent" || f.details.task_id !== undefined) {
		agents = [
			agentNodeFor(f, f.details, {
				key: "agent",
				prompt,
				output: ok && f.details.status !== "queued" ? f.output : undefined,
				error,
				elapsed: f.options.elapsedMs,
			}),
		];
	} else {
		agents = [];
	}
	const statuses =
		joined.length > 0 ? joined.map((entry) => taskStatus(f, entry)) : [taskStatus(f, f.details)];
	const failed = f.failed || statuses.some((status) => status === "failed" || status === "aborted");
	return {
		tool: head,
		tone: failed ? "error" : undefined,
		// The agent rows stay visible; each folds its own assignment and output.
		preview: "children",
		body: compact<NativeChild>([
			...agents,
			agents.length === 0 &&
				f.settled &&
				(f.failed
					? errorText(error ?? "Task failed")
					: noteText(f.output.trim() || "No results", "dim")),
		]),
	};
}

// -- omp delegates -------------------------------------------------------------------

/**
 * The `omp` tool: the session(s) it reports as `agent` nodes, the same nodes
 * the `/omp` panel draws. Ages are measured to the snapshot's own update time
 * so the view stays a pure function of the block; omp text is plain, never
 * markdown.
 */
function ompView(f: ToolFacts): NativeToolView {
	const action = safeLine(str(f.details.action) ?? str(f.args.action) ?? "omp", 20);
	if (f.failed) {
		return {
			tool: { title: "omp", meta: [action] },
			tone: "error",
			body: [errorText(safeText(failureMessage(f)))],
		};
	}
	if (action === "list" && Array.isArray(f.details.sessions)) {
		const sessions = parseOmpSessions(f.details.sessions);
		return {
			tool: {
				title: "omp",
				target: formatCount("session", sessions.length),
				targetKind: "text",
				meta: [action],
			},
			preview: "children",
			body:
				sessions.length > 0
					? sessions.map((session) =>
							ompAgentNode(session, {
								now: session.updatedAt ?? session.startedAt ?? 0,
								key: session.id,
							}),
						)
					: [noteText("No omp sessions", "dim")],
		};
	}
	if (action === "discover" && Array.isArray(f.details.sessions)) {
		const rows = parseOmpDiscoveredList(f.details.sessions);
		const lines = rows.map((row) => {
			const live = row.liveId ? ` · live ${row.liveId}` : "";
			return `${safeLine(row.ompSessionId, 13)}  ${safeLine(row.title, 80) || "(untitled)"} · ${safeLine(row.lastStatus, 20)}${live}`;
		});
		return {
			tool: {
				title: "omp",
				target: formatCount("stored session", rows.length),
				targetKind: "text",
				meta: [action],
			},
			body: [
				noteText(lines.join("\n") || "No stored omp sessions", lines.length > 0 ? "muted" : "dim"),
			],
		};
	}
	const session = parseOmpSession(f.details.session);
	if (!session) {
		const output = safeText(f.output).trim();
		return {
			tool: { title: "omp", meta: [action] },
			body: output ? [noteText(output)] : undefined,
		};
	}
	const todos = ompTodoProgress(session.todos);
	const delivery = str(f.details.delivery);
	return {
		tool: {
			title: "omp",
			target: ompSessionLabel(session),
			targetKind: "text",
			meta: compact([action, ompStatusText(session), todos ? `todos ${todos}` : undefined]),
		},
		tone: session.status === "failed" ? "error" : undefined,
		preview: "children",
		body: compact<NativeChild>([
			ompAgentNode(session, {
				now: session.updatedAt ?? session.startedAt ?? 0,
				key: session.id,
				collapsed: !f.options.expanded,
				children: ompDetailNodes(session),
			}),
			delivery ? noteText(`delivered as ${safeLine(delivery, 20)}`, "dim") : undefined,
		]),
	};
}
