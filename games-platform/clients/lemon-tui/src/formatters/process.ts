/**
 * Formatter for process tool results.
 *
 * Handles formatting of process management arguments and results,
 * including process listing, output logs, and status information.
 */

import type { ToolFormatter, FormattedOutput } from './types.js';
import { truncateText, truncateLines } from './base.js';

/** Maximum lines of output to show */
const OUTPUT_MAX_LINES = 15;

/** Column widths for process table */
const ID_WIDTH = 8;
const STATUS_WIDTH = 8;

/**
 * Arguments structure for process tool.
 */
interface ProcessArgs {
  action: 'list' | 'poll' | 'log' | 'write' | 'kill' | 'clear';
  process_id?: string;
  input?: string;
}

/**
 * Process info structure.
 */
interface ProcessInfo {
  id: string;
  status: 'running' | 'exited' | 'killed' | string;
  command?: string;
  exit_code?: number;
}

/**
 * Output line structure.
 */
interface OutputLine {
  stream: 'stdout' | 'stderr';
  text: string;
}

/**
 * Result structure from process tool.
 */
interface ProcessResult {
  processes?: ProcessInfo[];
  output?: OutputLine[] | string;
  lines?: OutputLine[] | string[];
  line_count?: number;
  process_id?: string;
  status?: string;
  content?: Array<{ type: string; text: string }>;
}

/**
 * Parses process list from a result object.
 *
 * @param result - The raw result from process tool
 * @returns Array of process info objects
 */
function parseProcessList(result: unknown): ProcessInfo[] {
  if (!result || typeof result !== 'object') {
    return [];
  }

  const obj = result as ProcessResult;

  if (Array.isArray(obj.processes)) {
    return obj.processes.filter(
      (p): p is ProcessInfo =>
        p !== null &&
        typeof p === 'object' &&
        typeof p.id === 'string' &&
        typeof p.status === 'string'
    );
  }

  return [];
}

/**
 * Parses output lines from a result object.
 *
 * @param result - The raw result from process tool
 * @returns Array of output lines
 */
function parseOutputLines(result: unknown): OutputLine[] {
  if (!result || typeof result !== 'object') {
    return [];
  }

  const obj = result as ProcessResult;

  // Check output field
  if (Array.isArray(obj.output)) {
    return obj.output.filter(
      (line): line is OutputLine =>
        line !== null &&
        typeof line === 'object' &&
        typeof line.stream === 'string' &&
        typeof line.text === 'string'
    );
  }

  // Check lines field
  if (Array.isArray(obj.lines)) {
    const lines: OutputLine[] = [];
    for (const line of obj.lines) {
      if (typeof line === 'string') {
        lines.push({ stream: 'stdout', text: line });
      } else if (
        line !== null &&
        typeof line === 'object' &&
        typeof (line as OutputLine).stream === 'string' &&
        typeof (line as OutputLine).text === 'string'
      ) {
        lines.push(line as OutputLine);
      }
    }
    return lines;
  }

  // Check for string output
  if (typeof obj.output === 'string') {
    return obj.output.split(/\r?\n/).map((text) => ({ stream: 'stdout' as const, text }));
  }

  return [];
}

/**
 * Formats a process table row.
 *
 * @param process - The process info
 * @returns Formatted table row
 */
function formatProcessRow(process: ProcessInfo): string {
  const id = process.id.padEnd(ID_WIDTH);
  const status = process.status.padEnd(STATUS_WIDTH);
  const command = process.command || '';
  return `${id} ${status} ${truncateText(command, 50)}`;
}

/**
 * Formats an output line with stream indicator.
 *
 * @param line - The output line
 * @returns Formatted output line
 */
function formatOutputLine(line: OutputLine): string {
  const streamTag = `[${line.stream}]`;
  return `${streamTag} ${line.text}`;
}

/**
 * Gets the line count from result.
 *
 * @param result - The raw result
 * @param parsedLines - Already parsed output lines
 * @returns Line count
 */
function getLineCount(result: unknown, parsedLines: OutputLine[]): number {
  if (result && typeof result === 'object') {
    const obj = result as ProcessResult;
    if (typeof obj.line_count === 'number') {
      return obj.line_count;
    }
  }
  return parsedLines.length;
}

/**
 * Gets process ID from result.
 *
 * @param result - The raw result
 * @param args - The tool arguments
 * @returns Process ID or undefined
 */
function getProcessId(result: unknown, args?: Record<string, unknown>): string | undefined {
  if (result && typeof result === 'object') {
    const obj = result as ProcessResult;
    if (typeof obj.process_id === 'string') {
      return obj.process_id;
    }
  }
  if (args && typeof args.process_id === 'string') {
    return args.process_id;
  }
  return undefined;
}

/**
 * Formatter for process tool.
 *
 * Provides formatted output for process operations, showing:
 * - Process tables for list action
 * - Output lines for poll/log actions
 * - Status information for other actions
 */
export const processFormatter: ToolFormatter = {
  tools: ['process'],

  formatArgs(args: Record<string, unknown>): FormattedOutput {
    const processArgs = args as unknown as ProcessArgs;
    const action = processArgs.action || 'list';

    // Summary: action with process_id if present
    const summary = processArgs.process_id
      ? `${action}: ${processArgs.process_id}`
      : action;

    // Details: action and parameters
    const details: string[] = [];
    details.push(`action: ${action}`);

    if (processArgs.process_id) {
      details.push(`process_id: ${processArgs.process_id}`);
    }

    if (processArgs.input) {
      details.push(`input: ${truncateText(processArgs.input, 50)}`);
    }

    return {
      summary,
      details,
    };
  },

  formatResult(result: unknown, args?: Record<string, unknown>): FormattedOutput {
    const processArgs = args as unknown as ProcessArgs | undefined;
    const action = processArgs?.action || 'list';

    // Handle list action
    if (action === 'list') {
      const processes = parseProcessList(result);
      const count = processes.length;

      // Summary: count of processes
      const summary = `${count} process${count === 1 ? '' : 'es'}`;

      // Details: process table
      const details: string[] = [];

      if (count > 0) {
        // Table header
        const header = `${'ID'.padEnd(ID_WIDTH)} ${'STATUS'.padEnd(STATUS_WIDTH)} COMMAND`;
        details.push(header);

        // Table rows
        for (const process of processes) {
          details.push(formatProcessRow(process));
        }
      }

      return {
        summary,
        details: truncateLines(details, OUTPUT_MAX_LINES + 1), // +1 for header
      };
    }

    // Handle poll/log actions
    if (action === 'poll' || action === 'log') {
      const lines = parseOutputLines(result);
      const lineCount = getLineCount(result, lines);
      const processId = getProcessId(result, args);

      // Summary: process_id with line count
      const summary = processId
        ? `${processId}: ${lineCount} line${lineCount === 1 ? '' : 's'}`
        : `${lineCount} line${lineCount === 1 ? '' : 's'}`;

      // Details: output lines
      const details: string[] = [];
      for (const line of lines) {
        details.push(formatOutputLine(line));
      }

      return {
        summary,
        details: truncateLines(details, OUTPUT_MAX_LINES),
      };
    }

    // Handle other actions (write, kill, clear)
    const processId = getProcessId(result, args);
    const status = result && typeof result === 'object' && typeof (result as ProcessResult).status === 'string'
      ? (result as ProcessResult).status
      : 'completed';

    const summary = processId ? `${processId}: ${status}` : status!;

    return {
      summary,
      details: [],
    };
  },
};

export default processFormatter;
