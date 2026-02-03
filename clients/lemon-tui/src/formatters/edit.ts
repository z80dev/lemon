/**
 * Formatter for edit and multiedit tools.
 *
 * Displays file edit operations with diff-style output showing
 * additions, deletions, and context lines.
 */

import type { ToolFormatter, FormattedOutput } from './types.js';
import { formatPath, truncateText, truncateLines, extractText } from './base.js';

/** Maximum lines to show in diff output */
const MAX_DIFF_LINES = 12;

/** Maximum characters for old_text preview */
const MAX_PREVIEW_LENGTH = 60;

/**
 * Formats a unified diff text into styled lines.
 *
 * Parses diff output and prefixes each line with appropriate markers:
 * - Lines starting with "-" indicate removals
 * - Lines starting with "+" indicate additions
 * - Lines starting with "@@" are diff headers
 * - Other lines are context
 *
 * @param diffText - The unified diff text to format
 * @returns Array of formatted diff lines, truncated to MAX_DIFF_LINES
 */
export function formatDiff(diffText: string): string[] {
  if (!diffText) {
    return [];
  }

  const lines = diffText.split(/\r?\n/);
  const formattedLines: string[] = [];

  for (const line of lines) {
    // Skip empty lines at the end
    if (line === '' && formattedLines.length > 0) {
      // Keep empty lines within the diff for readability
      formattedLines.push('');
      continue;
    }

    if (line.startsWith('@@')) {
      // Diff header line
      formattedLines.push(line);
    } else if (line.startsWith('-')) {
      // Removal line
      formattedLines.push(line);
    } else if (line.startsWith('+')) {
      // Addition line
      formattedLines.push(line);
    } else if (line.startsWith(' ')) {
      // Context line (already has space prefix)
      formattedLines.push(line);
    } else if (line.length > 0) {
      // Other content - treat as context
      formattedLines.push(`  ${line}`);
    }
  }

  // Remove trailing empty lines
  while (formattedLines.length > 0 && formattedLines[formattedLines.length - 1] === '') {
    formattedLines.pop();
  }

  return truncateLines(formattedLines, MAX_DIFF_LINES);
}

/**
 * Edit tool arguments interface.
 */
interface EditArgs {
  path?: string;
  old_text?: string;
  new_text?: string;
}

/**
 * Multiedit tool arguments interface.
 */
interface MultiEditArgs {
  path?: string;
  edits?: Array<{ old_text?: string; new_text?: string }>;
}

/**
 * Tool result with content blocks.
 */
interface ToolResult {
  content?: Array<{ type?: string; text?: string }>;
  details?: {
    matched?: boolean;
    [key: string]: unknown;
  };
}

/**
 * Formatter for edit and multiedit tools.
 *
 * Handles formatting of file edit operations, displaying diffs
 * with syntax highlighting for additions and removals.
 */
export const editFormatter: ToolFormatter = {
  tools: ['edit', 'multiedit'],

  formatArgs(args: Record<string, unknown>): FormattedOutput {
    const path = args.path as string | undefined;
    const formattedPath = path ? formatPath(path) : 'unknown';

    // Check if this is a multiedit (has edits array)
    if (Array.isArray(args.edits)) {
      const multiArgs = args as unknown as MultiEditArgs;
      const editCount = multiArgs.edits?.length ?? 0;

      const details: string[] = [`Path: ${formattedPath}`];

      if (editCount > 0 && multiArgs.edits) {
        details.push(`Edits: ${editCount}`);
        // Show preview of first edit's old_text
        const firstEdit = multiArgs.edits[0];
        if (firstEdit?.old_text) {
          const preview = truncateText(
            firstEdit.old_text.replace(/\n/g, '\\n'),
            MAX_PREVIEW_LENGTH
          );
          details.push(`First match: "${preview}"`);
        }
      }

      return {
        summary: `${formattedPath} (${editCount} edit${editCount === 1 ? '' : 's'})`,
        details,
      };
    }

    // Single edit
    const editArgs = args as unknown as EditArgs;
    const details: string[] = [`Path: ${formattedPath}`];

    if (editArgs.old_text) {
      const preview = truncateText(
        editArgs.old_text.replace(/\n/g, '\\n'),
        MAX_PREVIEW_LENGTH
      );
      details.push(`Match: "${preview}"`);
    }

    return {
      summary: formattedPath,
      details,
    };
  },

  formatResult(result: unknown, args?: Record<string, unknown>): FormattedOutput {
    const path = args?.path as string | undefined;
    const formattedPath = path ? formatPath(path) : '';

    // Check if result indicates an error or no match
    const isError = checkIsError(result);

    // Extract diff text from result
    const diffText = extractText(result);

    // Determine if the edit was successful
    const matched = checkMatched(result);

    // Build summary
    let summary: string;
    if (isError) {
      summary = formattedPath ? `\u2717 Failed: ${formattedPath}` : '\u2717 Failed';
    } else if (matched === false) {
      summary = formattedPath ? `\u2717 No match found in ${formattedPath}` : '\u2717 No match found';
    } else {
      // Check if multiedit
      if (args && Array.isArray(args.edits)) {
        const editCount = (args.edits as unknown[]).length;
        summary = formattedPath
          ? `\u2713 Applied ${editCount} edit${editCount === 1 ? '' : 's'} to ${formattedPath}`
          : `\u2713 Applied ${editCount} edit${editCount === 1 ? '' : 's'}`;
      } else {
        summary = formattedPath ? `\u2713 Applied to ${formattedPath}` : '\u2713 Applied';
      }
    }

    // Format diff for details
    const details = diffText ? formatDiff(diffText) : [];

    return {
      summary,
      details,
      isError: isError || matched === false,
    };
  },
};

/**
 * Checks if the result indicates an error.
 *
 * @param result - The tool result
 * @returns True if the result indicates an error
 */
function checkIsError(result: unknown): boolean {
  if (!result || typeof result !== 'object') {
    return false;
  }

  const obj = result as Record<string, unknown>;

  if (obj.is_error === true || obj.isError === true || obj.error === true) {
    return true;
  }

  if (typeof obj.error === 'string' && obj.error.length > 0) {
    return true;
  }

  return false;
}

/**
 * Checks if the result indicates a successful match.
 *
 * @param result - The tool result
 * @returns True if matched, false if not matched, undefined if unknown
 */
function checkMatched(result: unknown): boolean | undefined {
  if (!result || typeof result !== 'object') {
    return undefined;
  }

  const obj = result as ToolResult;

  // Check details.matched field
  if (obj.details && typeof obj.details.matched === 'boolean') {
    return obj.details.matched;
  }

  // Check for "no match" in text content
  const text = extractText(result);
  if (text) {
    const lowerText = text.toLowerCase();
    if (lowerText.includes('no match') || lowerText.includes('not found')) {
      return false;
    }
  }

  // Assume success if we have content and no error indicators
  if (obj.content && Array.isArray(obj.content) && obj.content.length > 0) {
    return true;
  }

  return undefined;
}
