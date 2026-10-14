/**
 * Formatters for the shell tools: bash, bash_output, and kill_process.
 *
 * `bash` runs a command in the foreground (exit code badge plus output) or,
 * with `run_in_background`, starts a process and returns its id.
 * `bash_output` reports a background process's status, exit code, and output;
 * `kill_process` reports the outcome of stopping one. The two process tools
 * take the same `{process_id}` arguments, so each has its own formatter.
 */

import { extractText, truncateLines, truncateText } from "./base.js";
import type { FormattedOutput, ToolFormatter } from "./types.js";

/** Maximum length for command in summary */
const COMMAND_SUMMARY_MAX_LENGTH = 80;

/** Maximum length for an output line in a summary */
const OUTPUT_SUMMARY_MAX_LENGTH = 70;

/** Maximum lines of output to show in details */
const OUTPUT_MAX_LINES = 10;

/** Background process statuses that mean the process did not finish cleanly */
const FAILED_PROCESS_STATUSES: Record<string, true> = {
	error: true,
	killed: true,
	lost: true,
};

/**
 * Normalized view of a shell tool result. Every field is optional on the wire.
 */
interface ParsedShellResult {
	/** Exit code, when the result reports one */
	exitCode: number | undefined;
	stdout: string;
	stderr: string;
	processId: string | undefined;
	status: string | undefined;
	/** Whether the tool call itself failed */
	toolError: boolean;
}

/**
 * Returns the value when it is a non-empty string.
 *
 * @param value - The value to check
 * @returns The string, or undefined
 */
function nonEmptyString(value: unknown): string | undefined {
	return typeof value === "string" && value.length > 0 ? value : undefined;
}

/**
 * Extracts the first non-empty line from text.
 *
 * @param text - The text to extract from
 * @returns The first non-empty line, or empty string
 */
function getFirstLine(text: string): string {
	for (const line of text.split(/\r?\n/)) {
		const trimmed = line.trim();
		if (trimmed) {
			return trimmed;
		}
	}
	return "";
}

/**
 * Splits output into its non-empty lines.
 *
 * @param text - The output text
 * @returns Non-empty lines
 */
function outputLines(text: string): string[] {
	return text.split(/\r?\n/).filter((line) => line.length > 0);
}

/**
 * Parses a shell tool result into exit code, output streams, and process info.
 *
 * Output comes from `details.stdout`/`details.stderr` when present, otherwise
 * from the result's text content.
 *
 * @param result - The raw tool result
 * @returns Parsed result
 */
function parseResult(result: unknown): ParsedShellResult {
	const parsed: ParsedShellResult = {
		exitCode: undefined,
		stdout: "",
		stderr: "",
		processId: undefined,
		status: undefined,
		toolError: false,
	};

	if (typeof result === "string") {
		parsed.stdout = result;
		return parsed;
	}

	if (!result || typeof result !== "object") {
		return parsed;
	}

	const obj = result as { details?: unknown; is_error?: unknown };
	parsed.toolError = obj.is_error === true;

	if (obj.details && typeof obj.details === "object") {
		const details = obj.details as Record<string, unknown>;
		if (typeof details.exit_code === "number") {
			parsed.exitCode = details.exit_code;
		}
		parsed.stdout = nonEmptyString(details.stdout) ?? "";
		parsed.stderr = nonEmptyString(details.stderr) ?? "";
		parsed.processId = nonEmptyString(details.process_id);
		parsed.status = nonEmptyString(details.status);
	}

	if (!parsed.stdout && !parsed.stderr) {
		const text = extractText(result);
		if (parsed.toolError) {
			parsed.stderr = text;
		} else {
			parsed.stdout = text;
		}
	}

	return parsed;
}

/**
 * Appends stdout lines and a labelled stderr section to details.
 *
 * @param details - The details array to append to
 * @param parsed - The parsed result
 */
function pushOutput(details: string[], parsed: ParsedShellResult): void {
	if (parsed.stdout) {
		details.push(...truncateLines(outputLines(parsed.stdout), OUTPUT_MAX_LINES));
	}

	const stderrLines = parsed.stderr ? outputLines(parsed.stderr) : [];
	if (stderrLines.length > 0) {
		if (details.length > 0) {
			details.push(""); // Empty line separator
		}
		details.push("stderr:");
		details.push(...truncateLines(stderrLines, OUTPUT_MAX_LINES));
	}
}

/**
 * Formats the arguments of a process tool (`{process_id}`).
 *
 * @param args - The tool arguments
 * @returns Formatted output
 */
function formatProcessArgs(args: Record<string, unknown>): FormattedOutput {
	const processId = nonEmptyString(args.process_id) ?? "";
	return {
		summary: processId,
		details: processId ? [`process_id: ${processId}`] : [],
	};
}

/**
 * Formats a foreground `bash` result: exit code badge plus output.
 *
 * @param parsed - The parsed result
 * @returns Formatted output
 */
function formatForegroundResult(parsed: ParsedShellResult): FormattedOutput {
	const failed = parsed.exitCode !== undefined ? parsed.exitCode !== 0 : parsed.toolError;
	const statusLabel = failed ? "Failed" : "Success";
	const firstLine = getFirstLine(parsed.stdout || parsed.stderr);
	const shownLine = firstLine ? truncateText(firstLine, OUTPUT_SUMMARY_MAX_LENGTH) : "";

	let summary: string;
	let statusLine: string;
	if (parsed.exitCode !== undefined) {
		const badge = `[${parsed.exitCode}]`;
		summary = shownLine ? `${badge} ${shownLine}` : badge;
		statusLine = `${badge} ${statusLabel}`;
	} else {
		summary = shownLine || statusLabel.toLowerCase();
		statusLine = statusLabel;
	}

	const details: string[] = [statusLine];
	pushOutput(details, parsed);

	return {
		summary,
		details,
		isError: failed,
	};
}

/**
 * Formats a `bash` result for a command started with `run_in_background`.
 *
 * @param parsed - The parsed result
 * @returns Formatted output
 */
function formatBackgroundStart(parsed: ParsedShellResult): FormattedOutput {
	const details: string[] = [];

	if (parsed.toolError && parsed.status !== "unknown") {
		const firstLine = getFirstLine(parsed.stderr || parsed.stdout);
		pushOutput(details, parsed);
		return {
			summary: firstLine
				? `background start failed: ${truncateText(firstLine, OUTPUT_SUMMARY_MAX_LENGTH)}`
				: "background start failed",
			details,
			isError: true,
		};
	}

	if (parsed.processId) {
		details.push(`process_id: ${parsed.processId}`);
	}
	if (parsed.status) {
		details.push(`status: ${parsed.status}`);
	}
	pushOutput(details, parsed);
	const admission =
		parsed.status === "queued"
			? "queued in background"
			: parsed.status === "unknown"
				? "background outcome unknown"
				: "started in background";

	return {
		summary: parsed.processId ? `${admission}: ${parsed.processId}` : admission,
		details,
		isError: parsed.toolError || parsed.status === "unknown",
	};
}

/**
 * Formatter for the `bash` tool.
 */
export const bashFormatter: ToolFormatter = {
	tools: ["bash"],

	formatArgs(args: Record<string, unknown>): FormattedOutput {
		const command = typeof args.command === "string" ? args.command : "";
		const background = args.run_in_background === true;

		const shownCommand = truncateText(command, COMMAND_SUMMARY_MAX_LENGTH);
		const summary = background ? `${shownCommand} (background)` : shownCommand;

		const details: string[] = [command];
		if (background) {
			details.push("background: true");
		}
		if (typeof args.timeout === "number") {
			details.push(`timeout: ${args.timeout}ms`);
		}
		if (args.pty === true) {
			details.push("pty: true");
		}

		return {
			summary,
			details,
		};
	},

	formatResult(result: unknown, args?: Record<string, unknown>): FormattedOutput {
		const parsed = parseResult(result);

		// A background start reports a process id instead of an exit code.
		const background =
			args?.run_in_background === true ||
			(parsed.processId !== undefined && parsed.exitCode === undefined);

		return background ? formatBackgroundStart(parsed) : formatForegroundResult(parsed);
	},

	formatPartial(partial: unknown, _args?: Record<string, unknown>): FormattedOutput {
		// Streaming updates carry a rolling output preview and no exit code yet.
		const lines = outputLines(extractText(partial));
		const lastLine = lines.length > 0 ? lines[lines.length - 1].trim() : "";

		return {
			summary: lastLine ? truncateText(lastLine, OUTPUT_SUMMARY_MAX_LENGTH) : "running",
			details: lines.slice(-OUTPUT_MAX_LINES),
		};
	},
};

/**
 * Formatter for the `bash_output` tool: status, exit code, and output of a
 * background process.
 */
export const bashOutputFormatter: ToolFormatter = {
	tools: ["bash_output"],

	formatArgs: formatProcessArgs,

	formatResult(result: unknown, args?: Record<string, unknown>): FormattedOutput {
		const parsed = parseResult(result);
		const processId = parsed.processId ?? nonEmptyString(args?.process_id);

		const failed =
			parsed.toolError ||
			(parsed.status !== undefined && FAILED_PROCESS_STATUSES[parsed.status] === true) ||
			(parsed.exitCode !== undefined && parsed.exitCode !== 0);

		const head: string[] = [];
		if (parsed.status) {
			head.push(parsed.status);
		}
		if (parsed.exitCode !== undefined) {
			head.push(`[${parsed.exitCode}]`);
		}
		const firstLine = getFirstLine(parsed.stdout || parsed.stderr);
		if (firstLine) {
			head.push(truncateText(firstLine, OUTPUT_SUMMARY_MAX_LENGTH));
		}

		const details: string[] = [];
		if (processId) {
			details.push(`process_id: ${processId}`);
		}
		if (parsed.status) {
			details.push(`status: ${parsed.status}`);
		}
		if (parsed.exitCode !== undefined) {
			details.push(`exit code: ${parsed.exitCode}`);
		}
		pushOutput(details, parsed);

		return {
			summary: head.length > 0 ? head.join(" ") : failed ? "failed" : "no output",
			details,
			isError: failed,
		};
	},
};

/**
 * Formatter for the `kill_process` tool.
 */
export const killProcessFormatter: ToolFormatter = {
	tools: ["kill_process"],

	formatArgs: formatProcessArgs,

	formatResult(result: unknown, args?: Record<string, unknown>): FormattedOutput {
		const parsed = parseResult(result);
		const processId = parsed.processId ?? nonEmptyString(args?.process_id);

		const details: string[] = [];
		if (processId) {
			details.push(`process_id: ${processId}`);
		}
		if (parsed.status) {
			details.push(`status: ${parsed.status}`);
		}
		pushOutput(details, parsed);

		if (parsed.toolError) {
			const firstLine = getFirstLine(parsed.stderr || parsed.stdout);
			return {
				summary: firstLine
					? `kill failed: ${truncateText(firstLine, OUTPUT_SUMMARY_MAX_LENGTH)}`
					: "kill failed",
				details,
				isError: true,
			};
		}

		let summary: string;
		if (parsed.status === undefined || parsed.status === "killed") {
			summary = processId ? `killed ${processId}` : "killed";
		} else {
			summary = processId ? `${processId}: ${parsed.status}` : parsed.status;
		}

		return {
			summary,
			details,
			isError: false,
		};
	},
};

export default [bashFormatter, bashOutputFormatter, killProcessFormatter];
