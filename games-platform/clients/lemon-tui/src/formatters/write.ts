/**
 * Formatter for write tool results.
 *
 * Handles formatting of file write operations, showing file path,
 * content preview, and operation status (created vs updated).
 */

import type { ToolFormatter, FormattedOutput } from './types.js';
import { formatPath, formatBytes, truncateText } from './base.js';

/**
 * Arguments structure for write tool.
 */
interface WriteArgs {
  path: string;
  content: string;
}

/**
 * Details structure from write result.
 */
interface WriteDetails {
  bytes_written: number;
  created: boolean;
}

/**
 * Result structure from write tool.
 */
interface WriteResult {
  content?: Array<{ type: string; text: string }>;
  details?: WriteDetails;
}

/**
 * Counts the number of lines in content.
 *
 * @param content - The content to count lines in
 * @returns The number of lines
 */
function countLines(content: string): number {
  if (!content) {
    return 0;
  }
  // Count newlines + 1, unless content ends with newline
  const lines = content.split(/\r?\n/);
  // If last line is empty (content ends with newline), don't count it
  if (lines.length > 0 && lines[lines.length - 1] === '') {
    return lines.length - 1;
  }
  return lines.length;
}

/**
 * Gets the first non-empty line from content.
 *
 * @param content - The content to extract from
 * @returns The first non-empty line
 */
function getFirstLine(content: string): string {
  if (!content) {
    return '';
  }
  const lines = content.split(/\r?\n/);
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed) {
      return trimmed;
    }
  }
  return '';
}

/**
 * Parses the result to extract write details.
 *
 * @param result - The raw result from write tool
 * @returns Parsed details with bytes_written and created status
 */
function parseResult(result: unknown): { bytesWritten: number; created: boolean } {
  let bytesWritten = 0;
  let created = false;

  if (result && typeof result === 'object') {
    const obj = result as WriteResult;
    if (obj.details) {
      bytesWritten = obj.details.bytes_written ?? 0;
      created = obj.details.created ?? false;
    }
  }

  return { bytesWritten, created };
}

/**
 * Formatter for write tool.
 *
 * Provides formatted output for file write operations, showing:
 * - File path (shortened)
 * - Content preview
 * - Operation status (created/updated)
 * - Bytes written
 */
export const writeFormatter: ToolFormatter = {
  tools: ['write'],

  formatArgs(args: Record<string, unknown>): FormattedOutput {
    const writeArgs = args as unknown as WriteArgs;
    const path = writeArgs.path || '';
    const content = writeArgs.content || '';

    // Summary: shortened path
    const shortPath = formatPath(path);
    const summary = shortPath;

    // Details: path, content preview (first line + line count)
    const details: string[] = [];
    details.push(shortPath);

    const lineCount = countLines(content);
    const firstLine = getFirstLine(content);
    if (firstLine) {
      details.push(`Preview: ${truncateText(firstLine, 60)}`);
    }
    details.push(`${lineCount} line${lineCount === 1 ? '' : 's'}`);

    return {
      summary,
      details,
    };
  },

  formatResult(result: unknown, args?: Record<string, unknown>): FormattedOutput {
    const { bytesWritten, created } = parseResult(result);
    const writeArgs = (args || {}) as unknown as WriteArgs;
    const path = writeArgs.path || '';
    const content = writeArgs.content || '';

    const shortPath = formatPath(path);
    const lineCount = countLines(content);
    const status = created ? 'Created' : 'Updated';

    // Summary: "Created ./src/new.ts (42 lines)" or "Updated ./src/existing.ts (42 lines)"
    const summary = `\u2713 ${status} ${shortPath} (${lineCount} line${lineCount === 1 ? '' : 's'})`;

    // Details: status, bytes written, path
    const details: string[] = [];
    details.push(`\u2713 ${status}`);
    details.push(`${lineCount} line${lineCount === 1 ? '' : 's'}, ${formatBytes(bytesWritten)}`);
    details.push(shortPath);

    return {
      summary,
      details,
    };
  },
};

export default writeFormatter;
