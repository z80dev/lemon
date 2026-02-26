/**
 * Formatters for file listing tools (find, glob, ls).
 *
 * Handles formatting of file search and directory listing arguments and results,
 * including file counts, type indicators, and truncated listings.
 */

import type { ToolFormatter, FormattedOutput } from './types.js';
import { formatPath, truncateLines, extractText } from './base.js';

/** Maximum number of files to show in details */
const MAX_FILES_SHOWN = 10;

/**
 * Arguments structure for find tool.
 */
interface FindArgs {
  pattern: string;
  path?: string;
  type?: 'f' | 'd';
  max_depth?: number;
  max_results?: number;
}

/**
 * Arguments structure for glob tool.
 */
interface GlobArgs {
  pattern: string;
  path?: string;
  max_results?: number;
}

/**
 * Arguments structure for ls tool.
 */
interface LsArgs {
  path?: string;
  all?: boolean;
  long?: boolean;
  recursive?: boolean;
  max_depth?: number;
  max_entries?: number;
}

/**
 * Gets a file type indicator based on path.
 *
 * @param path - The file path to analyze
 * @returns Type indicator character or empty string
 */
function getFileTypeIndicator(path: string): string {
  // Directory if ends with /
  if (path.endsWith('/')) {
    return '/';
  }
  return '';
}

/**
 * Parses file list from tool result.
 *
 * @param result - The raw result from the tool
 * @returns Array of file paths
 */
function parseFileList(result: unknown): string[] {
  const text = extractText(result);
  if (!text) {
    return [];
  }

  return text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
}

/**
 * Formats a file entry for display.
 *
 * @param filePath - The file path to format
 * @returns Formatted file entry with type indicator
 */
function formatFileEntry(filePath: string): string {
  const indicator = getFileTypeIndicator(filePath);
  // Remove trailing slash for display if it's a directory
  const displayPath = filePath.endsWith('/') ? filePath.slice(0, -1) : filePath;
  return displayPath + indicator;
}

/**
 * Builds flags string for ls command display.
 *
 * @param args - The ls arguments
 * @returns Flags string like "-la" or empty string
 */
function buildLsFlags(args: LsArgs): string {
  const flags: string[] = [];

  if (args.all) {
    flags.push('a');
  }
  if (args.long) {
    flags.push('l');
  }
  if (args.recursive) {
    flags.push('R');
  }

  return flags.length > 0 ? `-${flags.join('')}` : '';
}

/**
 * Formatter for find tool.
 *
 * Handles formatting of file search arguments and results.
 */
export const findFormatter: ToolFormatter = {
  tools: ['find'],

  formatArgs(args: Record<string, unknown>): FormattedOutput {
    const findArgs = args as unknown as FindArgs;
    const pattern = findArgs.pattern || '*';
    const path = findArgs.path;

    // Build summary
    let summary = pattern;
    if (path) {
      summary = `${pattern} in ${formatPath(path)}`;
    }

    // Build details
    const details: string[] = [];
    details.push(`pattern: ${pattern}`);

    if (path) {
      details.push(`path: ${formatPath(path)}`);
    }
    if (findArgs.type) {
      const typeLabel = findArgs.type === 'f' ? 'files' : 'directories';
      details.push(`type: ${typeLabel}`);
    }
    if (findArgs.max_depth !== undefined) {
      details.push(`max_depth: ${findArgs.max_depth}`);
    }
    if (findArgs.max_results !== undefined) {
      details.push(`max_results: ${findArgs.max_results}`);
    }

    return {
      summary,
      details,
    };
  },

  formatResult(result: unknown, _args?: Record<string, unknown>): FormattedOutput {
    const files = parseFileList(result);
    const count = files.length;

    // Build summary
    const summary = count === 0 ? 'No matches' : `${count} file${count === 1 ? '' : 's'} found`;

    // Build details with file list
    const details: string[] = [];
    if (count > 0) {
      const formattedFiles = files.map(formatFileEntry);
      const truncatedFiles = truncateLines(formattedFiles, MAX_FILES_SHOWN);
      details.push(...truncatedFiles);
    }

    return {
      summary,
      details,
    };
  },
};

/**
 * Formatter for glob tool.
 *
 * Handles formatting of glob pattern matching arguments and results.
 */
export const globFormatter: ToolFormatter = {
  tools: ['glob'],

  formatArgs(args: Record<string, unknown>): FormattedOutput {
    const globArgs = args as unknown as GlobArgs;
    const pattern = globArgs.pattern || '*';
    const path = globArgs.path;

    // Build summary
    let summary = pattern;
    if (path) {
      summary = `${pattern} in ${formatPath(path)}`;
    }

    // Build details
    const details: string[] = [];
    details.push(`pattern: ${pattern}`);

    if (path) {
      details.push(`path: ${formatPath(path)}`);
    }
    if (globArgs.max_results !== undefined) {
      details.push(`max_results: ${globArgs.max_results}`);
    }

    return {
      summary,
      details,
    };
  },

  formatResult(result: unknown, _args?: Record<string, unknown>): FormattedOutput {
    const files = parseFileList(result);
    const count = files.length;

    // Build summary
    const summary = count === 0 ? 'No matches' : `${count} file${count === 1 ? '' : 's'} found`;

    // Build details with file list
    const details: string[] = [];
    if (count > 0) {
      const formattedFiles = files.map(formatFileEntry);
      const truncatedFiles = truncateLines(formattedFiles, MAX_FILES_SHOWN);
      details.push(...truncatedFiles);
    }

    return {
      summary,
      details,
    };
  },
};

/**
 * Formatter for ls tool.
 *
 * Handles formatting of directory listing arguments and results.
 */
export const lsFormatter: ToolFormatter = {
  tools: ['ls'],

  formatArgs(args: Record<string, unknown>): FormattedOutput {
    const lsArgs = args as unknown as LsArgs;
    const path = lsArgs.path || '.';
    const flags = buildLsFlags(lsArgs);

    // Build summary
    const formattedPath = formatPath(path);
    const summary = flags ? `${formattedPath} ${flags}` : formattedPath;

    // Build details
    const details: string[] = [];
    details.push(`path: ${formattedPath}`);

    if (flags) {
      details.push(`flags: ${flags}`);
    }
    if (lsArgs.max_depth !== undefined) {
      details.push(`max_depth: ${lsArgs.max_depth}`);
    }
    if (lsArgs.max_entries !== undefined) {
      details.push(`max_entries: ${lsArgs.max_entries}`);
    }

    return {
      summary,
      details,
    };
  },

  formatResult(result: unknown, args?: Record<string, unknown>): FormattedOutput {
    const lsArgs = args as unknown as LsArgs | undefined;
    const path = lsArgs?.path || '.';
    const formattedPath = formatPath(path);

    const entries = parseFileList(result);
    const count = entries.length;

    // Build summary
    const summary = `${formattedPath} (${count} entr${count === 1 ? 'y' : 'ies'})`;

    // Build details with entry list
    const details: string[] = [];
    if (count > 0) {
      const formattedEntries = entries.map(formatFileEntry);
      const truncatedEntries = truncateLines(formattedEntries, MAX_FILES_SHOWN);
      details.push(...truncatedEntries);
    }

    return {
      summary,
      details,
    };
  },
};

export default [findFormatter, globFormatter, lsFormatter];
