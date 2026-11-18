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
 * ## The wire shape
 *
 * Every action comes from Lemon's native engine
 * (`CodingAgent.Session.RunTranslator`), projected for operator clients by the
 * control plane's event bridge. `action.detail` carries:
 *
 *   name            the tool name (`bash`, `edit`, `browser_click`, …)
 *   args            the tool's arguments, exactly as the model sent them
 *   result          the result text — bounded to ~32 KB for operator clients
 *                   (a server that predates that sends a 500-char preview)
 *   details         the tool's structured details, JSON-safe and bounded: an
 *                   edit's `diff` + `first_changed_line`, a command's
 *                   `exit_code`, a read's `path`/`total_lines`, …; optional
 *   result_meta     error/task/command metadata (`error_type`, `exit_code`, …)
 *   partial_result  the latest streamed partial, while the tool runs
 *
 * Reasoning never reaches this module: the event controller routes
 * `kind: "reasoning"` actions to their own transcript block.
 */

import { diffLines } from "@oh-my-pi/pi-natives";
import { displayText } from "../formatters/base.ts";
import { defaultRegistry, type FormatterRegistry } from "../formatters/index.ts";
import type { FormattedOutput } from "../formatters/types.ts";
import type { ToolBlock } from "../store/transcript-model.ts";

/** Live execution states and durable outcomes, including incomplete history. */
export type ToolCardState = "streaming" | "running" | "success" | "error" | "cancelled" | "unknown";

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
}

/** Body lines a card shows before the accordion starts eliding. */
export const MAX_BODY_LINES = 24;

function asString(value: unknown): string | undefined {
	return typeof value === "string" && value.length > 0 ? value : undefined;
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
	return value && typeof value === "object" && !Array.isArray(value)
		? (value as Record<string, unknown>)
		: undefined;
}

/**
 * The formatter key for an action: `detail.name`, or the tool name an error
 * path recorded in `result_meta`. Undefined for a bare note or an approval.
 */
export function resolveToolName(block: ToolBlock): string | undefined {
	const detail = block.detail ?? {};
	const raw = asString(detail.name) ?? asString(asRecord(detail.result_meta)?.tool_name);
	return raw?.trim().toLowerCase();
}

/** The tool's argument map (`detail.args`). */
export function toolArgs(block: ToolBlock): Record<string, unknown> {
	return asRecord(block.detail?.args) ?? {};
}

/** The tool's structured details (`detail.details`), when the server sent them. */
export function toolDetails(block: ToolBlock): Record<string, unknown> {
	return asRecord(block.detail?.details) ?? {};
}

/**
 * Rebuild the `{content, details, is_error}` result shape the formatters read:
 * the result text, and `result_meta` merged with the structured details.
 */
export function normalizeToolResult(block: ToolBlock, toolName?: string): unknown {
	const detail = block.detail ?? {};
	const text = asString(detail.result) ?? asString(block.message);
	const details: Record<string, unknown> = {
		...(asRecord(detail.result_meta) ?? {}),
		...toolDetails(block),
	};
	// The command formatters read their output from `details.stdout`/`stderr`
	// and ignore `content` once `details` is present. The server reports one
	// combined stream, so mirror it onto the side the exit status implies.
	if (text !== undefined && (toolName === "bash" || toolName === "bash_output")) {
		if (details.stdout === undefined && details.stderr === undefined) {
			if (isToolError(block)) details.stderr = text;
			else details.stdout = text;
		}
	}
	return {
		content: text === undefined ? [] : [{ type: "text", text }],
		details,
		is_error: isToolError(block),
	};
}

/** Cancellation is a terminal outcome, not an execution failure. */
export function isToolCancelled(block: ToolBlock): boolean {
	if (block.phase !== "completed") return false;
	const details = toolDetails(block);
	const meta = asRecord(block.detail?.result_meta);
	return (
		block.cancelled === true ||
		details.cancelled === true ||
		details.error_type === "aborted" ||
		meta?.error_type === "aborted"
	);
}

/** Whether the action failed: the event said so, or the result carries an error type. */
export function isToolError(block: ToolBlock): boolean {
	if (isToolCancelled(block)) return false;
	if (block.ok === false) return true;
	const meta = asRecord(block.detail?.result_meta);
	return meta?.error_type !== undefined && meta.error_type !== null;
}

/**
 * The lifecycle state. `streaming` is the window between the action being
 * announced and its arguments arriving.
 */
export function toolCardState(block: ToolBlock): ToolCardState {
	if (isToolCancelled(block)) return "cancelled";
	if (block.phase === "completed") {
		if (block.historical && block.ok === undefined && !isToolError(block)) return "unknown";
		return isToolError(block) ? "error" : "success";
	}
	if (block.historical) return "unknown";
	if (block.phase === "started" && block.detail === undefined) return "streaming";
	return "running";
}

/**
 * Render `old` → `new` as diff rows in the `±N|content` form {@link renderDiff}
 * parses. Removals number against the old text, additions against the new one,
 * context advances both.
 *
 * With a `startLine` the rows carry real file line numbers. Without one the
 * fragment's position in the file is unknown, so the rows carry no numbers at
 * all rather than numbers that would claim the edit sat at line 1.
 */
export function buildDiffText(oldText: string, newText: string, startLine?: number): string {
	const rows: string[] = [];
	let oldLine = startLine ?? 0;
	let newLine = startLine ?? 0;
	const num = (n: number) => (startLine === undefined ? "" : `${n}|`);
	for (const change of diffLines(oldText, newText)) {
		const value = change.value.endsWith("\n") ? change.value.slice(0, -1) : change.value;
		for (const content of value.split("\n")) {
			if (change.added) {
				rows.push(`+${num(newLine)}${content}`);
				newLine++;
			} else if (change.removed) {
				rows.push(`-${num(oldLine)}${content}`);
				oldLine++;
			} else {
				rows.push(` ${num(newLine)}${content}`);
				oldLine++;
				newLine++;
			}
		}
	}
	return rows.join("\n");
}

/** Context lines `diffLines` reports before the first changed row. */
function leadingContextLines(oldText: string, newText: string): number {
	let count = 0;
	for (const change of diffLines(oldText, newText)) {
		if (change.added || change.removed) return count;
		const value = change.value.endsWith("\n") ? change.value.slice(0, -1) : change.value;
		count += value.split("\n").length;
	}
	return count;
}

/** One row of the edit tool's diff: ` 12\tctx`, `-12\told`, `+12\tnew`. */
const SERVER_DIFF_ROW = /^([ +-])(\d+)\t(.*)$/;

/**
 * Convert the server's diff (`CodingAgent.Tools.Edit` format: marker, real
 * line number, tab, content; hunks separated by `...`) to renderDiff rows.
 */
export function serverDiffToRows(diff: string): string {
	return diff
		.split(/\r?\n/)
		.map((line) => {
			const match = SERVER_DIFF_ROW.exec(line);
			return match ? `${match[1]}${match[2]}|${match[3]}` : line;
		})
		.join("\n");
}

/** Unified-diff and patch-envelope noise that would be misparsed as content rows. */
const PATCH_HEADER =
	/^(diff --git |index |--- |\+\+\+ |@@|new file mode|deleted file mode|\*\*\* (Begin|End) Patch)/;

/** Keep a raw patch's hunk body, dropping its headers. */
export function stripUnifiedHeaders(patch: string): string {
	return patch
		.split(/\r?\n/)
		.filter((line) => !PATCH_HEADER.test(line))
		.join("\n")
		.trim();
}

/**
 * Pull a renderable diff out of an action, in descending order of fidelity:
 * the diff the tool itself computed (real line numbers), a patch, an edit's
 * old/new pair (anchored at `first_changed_line` when the server sent it), or a
 * whole-file write.
 */
export function extractToolDiff(
	block: ToolBlock,
	args: Record<string, unknown>,
	toolName: string | undefined,
): ToolDiff | undefined {
	const details = toolDetails(block);
	const path = asString(args.path) ?? asString(details.path);
	const serverDiff = asString(details.diff);
	if (serverDiff) return { path, text: serverDiffToRows(serverDiff) };
	if (toolName === "patch") {
		const patch = asString(args.patch_text);
		const text = patch ? stripUnifiedHeaders(patch) : "";
		return text.length > 0 ? { path, text } : undefined;
	}
	if (toolName === "edit") {
		const oldText = asString(args.old_text) ?? "";
		const newText = asString(args.new_text) ?? "";
		if (oldText.length === 0 && newText.length === 0) return undefined;
		const firstChanged = details.first_changed_line;
		const startLine =
			typeof firstChanged === "number" && Number.isInteger(firstChanged) && firstChanged > 0
				? Math.max(1, firstChanged - leadingContextLines(oldText, newText))
				: undefined;
		return { path, text: buildDiffText(oldText, newText, startLine) };
	}
	// A write replaces the file wholesale: every line is an addition, and the
	// numbering is the file's own.
	if (toolName === "write") {
		const content = asString(args.content);
		if (content === undefined) return undefined;
		const rows = content
			.split(/\r?\n/)
			.map((line, index) => `+${index + 1}|${line}`)
			.join("\n");
		return { path, text: rows };
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
	const args = toolArgs(block);
	const generic = toolName === undefined || !registry.hasFormatter(toolName);

	let formatted: FormattedOutput;
	if (kind === "note") {
		const retry = asRecord(block.detail?.retry);
		return displayView({
			state,
			kind,
			toolName,
			generic: false,
			title: block.title,
			summary: asString(block.detail?.text) ?? "",
			body: retry && asString(retry.reason) ? [asString(retry.reason)!] : [],
			isError: state === "error",
			diff: undefined,
		});
	}
	if (state === "streaming") {
		// Nothing is known yet. Running the formatters on an empty argument map
		// yields placeholder noise (`unknown`, `(no arguments)`), so the card shows
		// its header alone until the arguments land.
		formatted = { summary: "", details: [] };
	} else if (state === "cancelled" || state === "unknown") {
		const details = toolDetails(block);
		const labels = [state === "cancelled" ? "Cancelled" : "Outcome unknown"];
		if (state === "cancelled" && details.outcome === "unknown") labels.push("outcome unknown");
		if (details.outcome === "not_started") labels.push("not started");
		// Do not ask a success-oriented formatter to infer effects from arguments
		// (for example, a write's proposed content is not an applied file change).
		const output: string[] = [];
		for (const value of [block.detail?.result, details.stdout, details.stderr]) {
			if (typeof value === "string" && value.length > 0 && !output.includes(value)) {
				output.push(value);
			}
		}
		formatted = { summary: labels.join(" · "), details: output };
	} else if (state === "success" || state === "error") {
		formatted = formatCompleted(block, args, toolName, registry);
	} else if (block.detail?.partial_result !== undefined) {
		formatted = registry.formatPartial(toolName ?? "", block.detail.partial_result, args);
	} else {
		formatted = registry.formatArgs(toolName ?? "", args);
	}

	return displayView({
		state,
		kind,
		toolName,
		generic,
		title: block.title,
		summary: firstLine(formatted.summary),
		body: buildBody(formatted, block),
		isError: state === "error" || formatted.isError === true,
		// Only a known successful edit can claim its argument diff was applied.
		diff:
			state === "error" || state === "cancelled" || state === "unknown"
				? undefined
				: extractToolDiff(block, args, toolName),
	});
}

/**
 * Every string a card prints, made safe for the terminal: formatter output
 * interpolates argument keys, values and results verbatim, so the view is
 * escaped here once ({@link displayText}) rather than in each formatter.
 */
function displayView(view: ToolView): ToolView {
	return {
		...view,
		title: displayText(view.title),
		summary: displayText(view.summary),
		body: view.body.map(displayText),
		diff: view.diff && { ...view.diff, text: displayText(view.diff.text) },
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
	// A completed action with no result text at all would render an empty
	// card; the argument summary is the only thing left that says what ran.
	if (formatted.summary.length === 0 && formatted.details.length === 0) {
		formatted = { ...registry.formatArgs(toolName ?? "", args), isError: formatted.isError };
	}
	// A formatter that reads success out of the arguments alone (write derives
	// "✓ Updated <path>" from `content`) would contradict an event that says the
	// call failed. The event is authoritative: swap in what it said went wrong.
	if (formatted.isError !== true && isToolError(block)) {
		const detail = block.detail ?? {};
		const reason =
			asString(detail.result) ??
			asString(asRecord(detail.result_meta)?.message) ??
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

function buildBody(formatted: FormattedOutput, block: ToolBlock): string[] {
	const body: string[] = [];
	for (const line of formatted.details) {
		for (const part of String(line).split(/\r?\n/)) body.push(part);
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
