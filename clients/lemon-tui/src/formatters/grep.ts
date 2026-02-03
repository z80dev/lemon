/**
 * Formatter for the grep tool.
 *
 * Provides human-readable formatting of grep tool arguments and results,
 * including match highlighting and file grouping.
 */

import type { ToolFormatter, FormattedOutput } from './types.js';
import { extractText, highlightPattern, formatPath, truncateText } from './base.js';

/** Maximum number of files to show in details view */
const MAX_FILES = 10;

/** Maximum number of matches per file in details view */
const MAX_MATCHES_PER_FILE = 3;

/** Maximum length for content lines */
const MAX_LINE_LENGTH = 120;

/**
 * Represents a single grep match.
 */
interface GrepMatch {
  line: number;
  content: string;
}

/**
 * Parses grep output into a map grouped by file.
 *
 * Handles grep output formats:
 * - "filename:line_number:content" (standard grep -n output)
 * - "filename" (file list only, from -l flag)
 *
 * @param text - Raw grep output text
 * @returns Map from file path to array of matches
 */
export function parseGrepOutput(text: string): Map<string, GrepMatch[]> {
  const result = new Map<string, GrepMatch[]>();

  if (!text || text.trim() === '') {
    return result;
  }

  const lines = text.split(/\r?\n/);

  for (const line of lines) {
    if (!line.trim()) {
      continue;
    }

    // Try to parse as "filename:line_number:content"
    const match = line.match(/^(.+?):(\d+):(.*)$/);
    if (match) {
      const [, filePath, lineNumStr, content] = match;
      const lineNum = parseInt(lineNumStr, 10);

      if (!result.has(filePath)) {
        result.set(filePath, []);
      }
      result.get(filePath)!.push({
        line: lineNum,
        content: content,
      });
    } else {
      // Treat as just a filename (grep -l output)
      // Check if it looks like a file path (contains . or /)
      if (line.includes('/') || line.includes('.')) {
        if (!result.has(line)) {
          result.set(line, []);
        }
      }
    }
  }

  return result;
}

/**
 * Formats a line number with padding for alignment.
 *
 * @param lineNum - The line number to format
 * @param maxWidth - Maximum width for padding (default: 4)
 * @returns Formatted line number string
 */
function formatLineNumber(lineNum: number, maxWidth = 4): string {
  return String(lineNum).padStart(maxWidth, ' ');
}

/**
 * Formatter for the grep tool.
 *
 * Formats grep arguments showing the search pattern and scope,
 * and formats results with file grouping and match highlighting.
 */
export const grepFormatter: ToolFormatter = {
  tools: ['grep'],

  formatArgs(args: Record<string, unknown>): FormattedOutput {
    const pattern = args.pattern as string | undefined;
    const path = args.path as string | undefined;
    const glob = args.glob as string | undefined;
    const caseSensitive = args.case_sensitive as boolean | undefined;
    const contextLines = args.context_lines as number | undefined;

    // Build summary
    const parts: string[] = [];

    if (pattern) {
      parts.push(`"${pattern}"`);
    }

    if (path) {
      parts.push(`in ${formatPath(path)}`);
    }

    if (glob) {
      parts.push(`(${glob})`);
    }

    const summary = parts.length > 0 ? parts.join(' ') : '(no pattern)';

    // Build details
    const details: string[] = [];

    if (pattern) {
      details.push(`Pattern: "${pattern}"`);
    }

    if (path) {
      details.push(`Path: ${formatPath(path)}`);
    }

    if (glob) {
      details.push(`Glob: ${glob}`);
    }

    if (caseSensitive !== undefined) {
      details.push(`Case sensitive: ${caseSensitive}`);
    }

    if (contextLines !== undefined) {
      details.push(`Context lines: ${contextLines}`);
    }

    return { summary, details };
  },

  formatResult(result: unknown, args?: Record<string, unknown>): FormattedOutput {
    const text = extractText(result);
    const pattern = (args?.pattern as string) || '';

    // Check for error
    if (typeof result === 'object' && result !== null) {
      const obj = result as Record<string, unknown>;
      if (obj.is_error === true || obj.isError === true) {
        const errorText = text || 'Unknown error';
        return {
          summary: truncateText(errorText, 100),
          details: errorText.split(/\r?\n/),
          isError: true,
        };
      }
    }

    // Parse the grep output
    const matches = parseGrepOutput(text);

    // Handle no matches
    if (matches.size === 0) {
      return {
        summary: 'No matches',
        details: ['No matches found'],
      };
    }

    // Count total matches
    let totalMatches = 0;
    for (const fileMatches of matches.values()) {
      // If we have match details, count them; otherwise count the file itself
      totalMatches += fileMatches.length > 0 ? fileMatches.length : 1;
    }

    const fileCount = matches.size;

    // Build summary
    const matchWord = totalMatches === 1 ? 'match' : 'matches';
    const fileWord = fileCount === 1 ? 'file' : 'files';
    const summary = `${totalMatches} ${matchWord} in ${fileCount} ${fileWord}`;

    // Build details
    const details: string[] = [];
    const files = Array.from(matches.entries());
    const displayFiles = files.slice(0, MAX_FILES);

    // Default highlight function (uppercase for visibility in plain text)
    const highlightFn = (s: string) => `[${s}]`;

    for (const [filePath, fileMatches] of displayFiles) {
      const formattedPath = formatPath(filePath);
      const matchCount = fileMatches.length > 0 ? fileMatches.length : 1;
      const matchLabel = matchCount === 1 ? 'match' : 'matches';

      // Add file header
      details.push(`${formattedPath} (${matchCount} ${matchLabel})`);

      // Add match lines (limited)
      const displayMatches = fileMatches.slice(0, MAX_MATCHES_PER_FILE);
      for (const match of displayMatches) {
        const lineNumStr = formatLineNumber(match.line);
        let content = match.content;

        // Truncate long lines
        if (content.length > MAX_LINE_LENGTH) {
          content = content.slice(0, MAX_LINE_LENGTH - 3) + '...';
        }

        // Highlight pattern in content
        if (pattern) {
          content = highlightPattern(content, pattern, highlightFn);
        }

        details.push(`  ${lineNumStr}| ${content}`);
      }

      // Show truncation indicator for matches
      if (fileMatches.length > MAX_MATCHES_PER_FILE) {
        const remaining = fileMatches.length - MAX_MATCHES_PER_FILE;
        details.push(`  ... (${remaining} more)`);
      }
    }

    // Show truncation indicator for files
    if (files.length > MAX_FILES) {
      const remainingFiles = files.length - MAX_FILES;
      details.push(`... (${remainingFiles} more files)`);
    }

    return { summary, details };
  },
};
