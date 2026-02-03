/**
 * Formatter for bash/exec tool results.
 *
 * Handles formatting of command execution arguments and results,
 * including exit codes, stdout, and stderr output.
 */

import type { ToolFormatter, FormattedOutput } from './types.js';
import { truncateText, truncateLines, extractText } from './base.js';

/** Maximum length for command in summary */
const COMMAND_SUMMARY_MAX_LENGTH = 80;

/** Maximum lines of output to show in details */
const OUTPUT_MAX_LINES = 10;

/**
 * Arguments structure for bash/exec tools.
 */
interface BashArgs {
  command: string;
  timeout?: number;
  cwd?: string;
}

/**
 * Detailed result structure from bash execution.
 */
interface BashDetails {
  exit_code: number;
  stdout?: string;
  stderr?: string;
}

/**
 * Result structure from bash/exec tools.
 */
interface BashResult {
  content?: Array<{ type: string; text: string }>;
  details?: BashDetails;
}

/**
 * Formats the exit code as a badge string.
 *
 * @param exitCode - The exit code to format
 * @returns Formatted badge like "[0]" or "[1]"
 */
function formatExitCodeBadge(exitCode: number): string {
  return `[${exitCode}]`;
}

/**
 * Determines if an exit code represents success.
 *
 * @param exitCode - The exit code to check
 * @returns True if exit code indicates success (0)
 */
function isSuccess(exitCode: number): boolean {
  return exitCode === 0;
}

/**
 * Extracts the first non-empty line from text.
 *
 * @param text - The text to extract from
 * @returns The first non-empty line, or empty string
 */
function getFirstLine(text: string): string {
  const lines = text.split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed) {
      return trimmed;
    }
  }
  return '';
}

/**
 * Parses the result to extract exit code, stdout, and stderr.
 *
 * @param result - The raw result from bash tool
 * @returns Parsed details with exit_code, stdout, stderr
 */
function parseResult(result: unknown): { exitCode: number; stdout: string; stderr: string } {
  // Default values
  let exitCode = 0;
  let stdout = '';
  let stderr = '';

  // Handle string result
  if (typeof result === 'string') {
    stdout = result;
    return { exitCode, stdout, stderr };
  }

  // Handle object result
  if (result && typeof result === 'object') {
    const obj = result as BashResult;

    // Extract details if present
    if (obj.details) {
      exitCode = obj.details.exit_code ?? 0;
      stdout = obj.details.stdout ?? '';
      stderr = obj.details.stderr ?? '';
    }

    // If no details, try to extract text from content
    if (!obj.details && obj.content) {
      stdout = extractText(result);
    }
  }

  return { exitCode, stdout, stderr };
}

/**
 * Formatter for bash and exec tools.
 *
 * Provides formatted output for command execution, showing:
 * - Command summary with truncation
 * - Exit code badges (green for success, red for failure)
 * - Stdout and stderr output
 */
export const bashFormatter: ToolFormatter = {
  tools: ['bash', 'exec'],

  formatArgs(args: Record<string, unknown>): FormattedOutput {
    const bashArgs = args as unknown as BashArgs;
    const command = bashArgs.command || '';

    // Summary: truncated command
    const summary = truncateText(command, COMMAND_SUMMARY_MAX_LENGTH);

    // Details: full command and optional metadata
    const details: string[] = [];
    details.push(command);

    if (bashArgs.timeout !== undefined) {
      details.push(`timeout: ${bashArgs.timeout}ms`);
    }

    if (bashArgs.cwd) {
      details.push(`cwd: ${bashArgs.cwd}`);
    }

    return {
      summary,
      details,
    };
  },

  formatResult(result: unknown, _args?: Record<string, unknown>): FormattedOutput {
    const { exitCode, stdout, stderr } = parseResult(result);
    const badge = formatExitCodeBadge(exitCode);
    const success = isSuccess(exitCode);

    // Get first line of output for summary
    const outputText = stdout || stderr || '';
    const firstLine = getFirstLine(outputText);

    // Summary: badge + first line of output
    const summary = firstLine ? `${badge} ${truncateText(firstLine, 70)}` : badge;

    // Details: badge with status, then output lines
    const details: string[] = [];

    // Line 1: Exit code with status
    details.push(`${badge} ${success ? 'Success' : 'Failed'}`);

    // Add stdout lines
    if (stdout) {
      const stdoutLines = stdout.split(/\r?\n/).filter((line) => line.length > 0);
      const truncatedStdout = truncateLines(stdoutLines, OUTPUT_MAX_LINES);
      details.push(...truncatedStdout);
    }

    // Add stderr in warning style if present
    if (stderr) {
      const stderrLines = stderr.split(/\r?\n/).filter((line) => line.length > 0);
      if (stderrLines.length > 0) {
        details.push(''); // Empty line separator
        details.push('stderr:');
        const truncatedStderr = truncateLines(stderrLines, OUTPUT_MAX_LINES);
        details.push(...truncatedStderr);
      }
    }

    return {
      summary,
      details,
      isError: !success,
    };
  },
};

export default bashFormatter;
