/**
 * The adapter between the control plane's `tool_use` action and the pure
 * formatters in `src/formatters/`.
 *
 * This module is deliberately view-free: it takes a {@link ToolBlock} and
 * returns a {@link ToolView} — a state, a title, a one-line summary, body lines
 * and an optional diff payload. {@link ToolCardComponent}, {@link
 * ToolShelfComponent} and the gallery all render the same view, so what the
 * gallery shows is what the transcript shows.
 *
 * ## Why an adapter is needed at all
 *
 * `action.detail` is passed through the Elixir pipeline verbatim: every engine
 * adapter (claude, codex, opencode, kimi, pi, the native lemon engine) puts its
 * own keys in, and nothing normalises them. The formatters, in contrast, were
 * written against the native engine's tool argument shape. The three tables
 * below are the whole translation:
 *
 *   tool name  `detail.name` (claude/opencode/kimi/native) · `detail.tool_name`
 *              (pi) · `detail.tool` (codex MCP) · `detail.result_meta.tool_name`
 *              (native, error paths) · else inferred from `action.kind`
 *   arguments  `detail.input` (claude/opencode/kimi) · `detail.args` (pi/native)
 *              · `detail.arguments` (codex MCP)
 *   result     `detail.result` (pi/native) · `detail.result_preview`
 *              (claude/kimi/codex) · `detail.output_preview` (opencode) ·
 *              `detail.result_summary` (codex, duplicate) · `detail.error_message`
 *
 * On top of that, argument *keys* differ per engine (`file_path` vs `path`,
 * `old_string` vs `old_text`, `cmd` vs `command`), so {@link normalizeToolArgs}
 * fills in the canonical alias the formatters read without dropping anything the
 * engine sent.
 *
 * Codex is the one engine that reports shell commands with no tool name and no
 * detail at all on `started` — those fall through to the kind-based inference
 * (`command` → `bash`) and the action title, which already carries the command.
 */

import { diffLines } from "@oh-my-pi/pi-natives";
import { defaultRegistry, type FormatterRegistry } from "../formatters/index.ts";
import type { FormattedOutput } from "../formatters/types.ts";
import type { ToolBlock } from "../store/transcript-model.ts";

/** The four lifecycle states a tool card renders. */
export type ToolCardState = "streaming" | "running" | "success" | "error";

/** A diff the card can render in colour, over and above the formatter's lines. */
export interface ToolDiff {
	/** File the diff applies to, when the action named one. */
	path: string | undefined;
	/** Rows in `renderDiff` form: `±N|content`, or `±content` without numbers. */
	text: string;
}

export interface ToolView {
	state: ToolCardState;
	/** `action.kind`, or `"tool"` when the daemon sent an unmapped kind. */
	kind: string;
	/** Resolved formatter key, or undefined when nothing identified the tool. */
	toolName: string | undefined;
	/** True when no formatter is registered for {@link toolName}. */
	generic: boolean;
	title: string;
	/** One line. Never contains a newline. */
	summary: string;
	/** Body lines, already truncated by the formatter. Never styled. */
	body: string[];
	isError: boolean;
	diff: ToolDiff | undefined;
	/** Set for `reasoning`/`note` actions that carry a thought. */
	reasoning: string | undefined;
	/** Paths from `detail.changes`, for engines that report changes not diffs. */
	changedPaths: string[];
}

/** Body lines a card shows before the accordion starts eliding. */
export const MAX_BODY_LINES = 24;

/**
 * Tool names an engine reports that mean the same thing as a registered
 * formatter. Names are matched after lowercasing and stripping `_`/`-`/spaces,
 * so `Web_Search`, `webSearch` and `WEBSEARCH` all arrive here as `websearch`.
 */
const TOOL_NAME_ALIASES: Record<string, string> = {
	agent: "task",
	applypatch: "patch",
	execute: "bash",
	fetch: "webfetch",
	killshell: "bash",
	listdirectory: "ls",
	readfile: "read",
	run: "bash",
	runcommand: "bash",
	search: "grep",
	shell: "bash",
	strreplace: "edit",
	strreplaceeditor: "edit",
	todo: "todowrite",
	writefile: "write",
};

/** Kind → formatter key, for engines that report no tool name (codex). */
function toolNameForKind(kind: string, args: Record<string, unknown>): string | undefined {
	switch (kind) {
		case "command":
			return "bash";
		case "file_change":
			return "edit";
		case "web_search":
			return typeof args.url === "string" ? "webfetch" : "websearch";
		case "subagent":
			return "task";
		default:
			return undefined;
	}
}

function asString(value: unknown): string | undefined {
	return typeof value === "string" && value.length > 0 ? value : undefined;
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
	return value && typeof value === "object" && !Array.isArray(value)
		? (value as Record<string, unknown>)
		: undefined;
}

/** Normalise an engine's tool name to a formatter key. */
export function normalizeToolName(raw: string): string {
	const key = raw
		.trim()
		.toLowerCase()
		.replace(/[\s_-]/g, "");
	return TOOL_NAME_ALIASES[key] ?? key;
}

/**
 * Resolve the formatter key for an action, or undefined when neither the detail
 * nor the kind identifies a tool (a bare `note`, a null-kind engine warning).
 */
export function resolveToolName(block: ToolBlock): string | undefined {
	const detail = block.detail ?? {};
	const meta = asRecord(detail.result_meta);
	const raw =
		asString(detail.name) ??
		asString(detail.tool_name) ??
		asString(detail.tool) ??
		asString(meta?.tool_name);
	if (raw) return normalizeToolName(raw);
	return toolNameForKind(String(block.toolKind ?? ""), toolArgs(block));
}

/** The raw argument map, under whichever key the engine used. */
export function toolArgs(block: ToolBlock): Record<string, unknown> {
	const detail = block.detail ?? {};
	return asRecord(detail.input) ?? asRecord(detail.args) ?? asRecord(detail.arguments) ?? {};
}

/**
 * Add the argument keys the formatters read, keeping every key the engine sent.
 * Aliases only ever fill a gap: an engine that already speaks the canonical
 * name is passed through untouched.
 */
export function normalizeToolArgs(args: Record<string, unknown>): Record<string, unknown> {
	const out: Record<string, unknown> = { ...args };
	const fill = (canonical: string, ...aliases: string[]) => {
		if (out[canonical] !== undefined) return;
		for (const alias of aliases) {
			if (args[alias] !== undefined) {
				out[canonical] = args[alias];
				return;
			}
		}
	};
	fill("path", "file_path", "filePath", "filename", "file", "target_file");
	fill("old_text", "old_string", "oldString", "oldText");
	fill("new_text", "new_string", "newString", "newText");
	fill("command", "cmd", "script");
	fill("patch_text", "patch", "diff");
	fill("pattern", "regex");
	return out;
}

/**
 * Rebuild the `{content, details, is_error}` result shape the formatters were
 * written against out of whatever flat keys the engine reported.
 */
export function normalizeToolResult(block: ToolBlock, toolName?: string): unknown {
	const detail = block.detail ?? {};
	const text =
		asString(detail.result) ??
		asString(detail.result_preview) ??
		asString(detail.output_preview) ??
		asString(detail.result_summary) ??
		asString(detail.error_message) ??
		asString(block.message);
	// `result` is occasionally a structured payload rather than a string (pi
	// forwards the tool's own return value); the formatters know those shapes,
	// so hand them through rather than stringifying.
	const structured = asRecord(detail.result);
	if (structured && (structured.content !== undefined || structured.details !== undefined)) {
		return structured;
	}
	const details: Record<string, unknown> = { ...(asRecord(detail.result_meta) ?? {}) };
	if (detail.exit_code !== undefined && details.exit_code === undefined) {
		details.exit_code = detail.exit_code;
	}
	if (Array.isArray(detail.changes) && details.files === undefined) {
		details.files = detail.changes;
	}
	// The command formatters read their output from `details.stdout`/`stderr`
	// and ignore `content` entirely once `details` is present. Engines report a
	// single combined stream, so mirror it onto the side the exit status implies.
	if (text !== undefined && (toolName === "bash" || toolName === "exec")) {
		const failed = isToolError(block);
		if (details.stdout === undefined && details.stderr === undefined) {
			if (failed) details.stderr = text;
			else details.stdout = text;
		}
	}
	return {
		content: text === undefined ? [] : [{ type: "text", text }],
		details,
		is_error: isToolError(block),
	};
}

/** Whether the action failed, across the four error shapes engines report. */
export function isToolError(block: ToolBlock): boolean {
	if (block.ok === false) return true;
	const detail = block.detail ?? {};
	if (detail.is_error === true || detail.isError === true) return true;
	if (asString(detail.error_message) !== undefined) return true;
	if (asString(detail.error) !== undefined) return true;
	const meta = asRecord(detail.result_meta);
	return meta?.error_type !== undefined && meta.error_type !== null;
}

/**
 * The lifecycle state. `streaming` is the window between the action being
 * announced and its arguments arriving — codex opens a `command` action with an
 * empty detail, and claude streams tool input in.
 */
export function toolCardState(block: ToolBlock): ToolCardState {
	if (block.phase === "completed") return isToolError(block) ? "error" : "success";
	const args = toolArgs(block);
	const hasArgs = Object.keys(args).length > 0;
	if (block.phase === "started" && !hasArgs && block.detail === undefined) return "streaming";
	return "running";
}

/** The reasoning text an action carries, if any. */
function reasoningText(block: ToolBlock): string | undefined {
	const reasoning = asRecord(block.detail?.reasoning);
	return asString(reasoning?.text);
}

function changedPaths(block: ToolBlock): string[] {
	const changes = block.detail?.changes;
	if (!Array.isArray(changes)) return [];
	const paths: string[] = [];
	for (const change of changes) {
		const path = asString(asRecord(change)?.path);
		if (path) paths.push(path);
	}
	return paths;
}

/**
 * Render `old` → `new` as diff rows with old-side line numbers, in the
 * `±N|content` form {@link renderDiff} parses.
 *
 * The line numbers are relative to the replaced fragment (an engine that sends
 * `old_string`/`new_string` never says where in the file it sat), which is why
 * they start at 1 unless a caller knows better.
 */
export function buildDiffText(oldText: string, newText: string, startLine = 1): string {
	const rows: string[] = [];
	// Removals number against the old text, additions against the new one, and
	// context advances both — otherwise a replacement renders as `-1 / +2`,
	// implying the edit moved the line down a row.
	let oldLine = startLine;
	let newLine = startLine;
	for (const change of diffLines(oldText, newText)) {
		const value = change.value.endsWith("\n") ? change.value.slice(0, -1) : change.value;
		for (const content of value.split("\n")) {
			if (change.added) {
				rows.push(`+${newLine}|${content}`);
				newLine++;
			} else if (change.removed) {
				rows.push(`-${oldLine}|${content}`);
				oldLine++;
			} else {
				rows.push(` ${newLine}|${content}`);
				oldLine++;
				newLine++;
			}
		}
	}
	return rows.join("\n");
}

/** Unified-diff noise that would be misparsed as content rows. */
const UNIFIED_HEADER = /^(diff --git |index |--- |\+\+\+ |@@|new file mode|deleted file mode)/;

/** Keep a raw unified diff's hunk body, dropping its headers. */
export function stripUnifiedHeaders(patch: string): string {
	return patch
		.split(/\r?\n/)
		.filter((line) => !UNIFIED_HEADER.test(line))
		.join("\n")
		.trim();
}

/**
 * Pull a renderable diff out of an action, in descending order of fidelity:
 * an explicit patch, an old/new pair, or a whole-file write.
 */
export function extractToolDiff(
	block: ToolBlock,
	args: Record<string, unknown>,
	toolName: string | undefined,
): ToolDiff | undefined {
	const path = asString(args.path);
	const patch = asString(args.patch_text);
	if (patch) {
		const text = stripUnifiedHeaders(patch);
		return text.length > 0 ? { path, text } : undefined;
	}
	const oldText = asString(args.old_text);
	const newText = asString(args.new_text);
	if (oldText !== undefined || newText !== undefined) {
		return { path, text: buildDiffText(oldText ?? "", newText ?? "") };
	}
	// A write replaces the file wholesale: every line is an addition. Only for
	// `write` — `content` means something else on most other tools.
	const content = toolName === "write" ? asString(args.content) : undefined;
	if (content !== undefined) {
		const rows = content
			.split(/\r?\n/)
			.map((line, index) => `+${index + 1}|${line}`)
			.join("\n");
		return { path, text: rows };
	}
	// Multi-edit: diff the first edit so the card shows something concrete.
	const edits = Array.isArray(args.edits) ? args.edits : undefined;
	const first = asRecord(edits?.[0]);
	if (first) {
		const from = asString(first.old_text) ?? asString(first.old_string) ?? "";
		const to = asString(first.new_text) ?? asString(first.new_string) ?? "";
		if (from || to) return { path, text: buildDiffText(from, to) };
	}
	if (block.detail?.diff !== undefined) {
		const raw = asString(block.detail.diff);
		if (raw) return { path, text: stripUnifiedHeaders(raw) };
	}
	return undefined;
}

/**
 * Everything a card, a shelf line or the gallery needs to render one tool
 * action. Pure: the same block always yields the same view.
 */
export function buildToolView(
	block: ToolBlock,
	registry: FormatterRegistry = defaultRegistry,
): ToolView {
	const state = toolCardState(block);
	const kind = String(block.toolKind ?? "tool");
	const toolName = resolveToolName(block);
	const rawArgs = toolArgs(block);
	const args = normalizeToolArgs(rawArgs);
	const generic = toolName === undefined || !registry.hasFormatter(toolName);
	const reasoning = reasoningText(block);

	let formatted: FormattedOutput;
	if (reasoning !== undefined) {
		const lines = reasoning.split(/\r?\n/);
		formatted = { summary: lines[0] ?? "", details: lines };
	} else if (state === "streaming") {
		// Nothing is known yet. Running the formatters on an empty argument map
		// yields placeholder noise (`unknown`, `(no arguments)`), so the card shows
		// its header alone until the arguments land.
		formatted = { summary: "", details: [] };
	} else if (state === "success" || state === "error") {
		formatted = formatCompleted(block, args, toolName, registry);
	} else if (block.detail?.partial_result !== undefined) {
		formatted = registry.formatPartial(toolName ?? "", block.detail.partial_result, args);
	} else {
		formatted = registry.formatArgs(toolName ?? "", args);
	}

	const paths = changedPaths(block);
	const body = buildBody(formatted, block, paths);
	return {
		state,
		kind,
		toolName,
		generic,
		title: block.title,
		summary: firstLine(formatted.summary),
		body,
		isError: state === "error" || formatted.isError === true,
		diff: reasoning === undefined ? extractToolDiff(block, args, toolName) : undefined,
		reasoning,
		changedPaths: paths,
	};
}

function formatCompleted(
	block: ToolBlock,
	args: Record<string, unknown>,
	toolName: string | undefined,
	registry: FormatterRegistry,
): FormattedOutput {
	const result = normalizeToolResult(block, toolName);
	let formatted = registry.formatResult(toolName ?? "", result, args);
	// A completed action with no result text at all (codex commands report only
	// an exit code) would render an empty card; the argument summary is the only
	// thing left that says what ran.
	if (formatted.summary.length === 0 && formatted.details.length === 0) {
		formatted = { ...registry.formatArgs(toolName ?? "", args), isError: formatted.isError };
	}
	// A formatter that reads success out of the arguments alone (write derives
	// "✓ Updated <path>" from `content`) would contradict an event that says the
	// call failed. The event is authoritative: swap in what it said went wrong.
	if (formatted.isError !== true && isToolError(block)) {
		const detail = block.detail ?? {};
		const reason =
			asString(detail.error) ??
			asString(detail.error_message) ??
			asString(asRecord(detail.result_meta)?.reason) ??
			asString(block.message);
		return {
			summary: reason ?? formatted.summary,
			details: formatted.details,
			isError: true,
		};
	}
	return formatted;
}

function buildBody(
	formatted: FormattedOutput,
	block: ToolBlock,
	paths: readonly string[],
): string[] {
	const body: string[] = [];
	for (const line of formatted.details) {
		for (const part of String(line).split(/\r?\n/)) body.push(part);
	}
	if (body.length === 0 && paths.length > 0) {
		for (const path of paths) body.push(path);
	}
	// The daemon's own message (an approval note, a timeout reason) is not part
	// of any formatter's output but is often the only explanation of a failure.
	const message = block.message?.trim();
	if (message && !body.some((line) => line.includes(message))) body.push(message);
	return body.length > MAX_BODY_LINES
		? [...body.slice(0, MAX_BODY_LINES), `… ${body.length - MAX_BODY_LINES} more lines`]
		: body;
}

function firstLine(text: string): string {
	const line = text.split(/\r?\n/, 1)[0] ?? "";
	return line.trim();
}
