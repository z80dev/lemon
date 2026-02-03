/**
 * Formatter for patch tool results.
 *
 * Handles formatting of patch operations, parsing unified diff format
 * to show affected files and operation types (create, modify, delete).
 */

import type { ToolFormatter, FormattedOutput } from './types.js';
import { formatPath } from './base.js';

/**
 * Arguments structure for patch tool.
 */
interface PatchArgs {
  patch_text: string;
}

/**
 * Represents a file operation detected from patch headers.
 */
interface FileOperation {
  path: string;
  operation: 'created' | 'modified' | 'deleted';
  additions?: number;
  deletions?: number;
}

/**
 * Parses patch text to extract file operations.
 *
 * Detects:
 * - New file: has "+++ b/path" but "--- /dev/null"
 * - Deleted: has "--- a/path" but "+++ /dev/null"
 * - Modified: has both "--- a/path" and "+++ b/path"
 *
 * @param patchText - The unified diff patch text
 * @returns Array of file operations detected
 */
function parsePatchOperations(patchText: string): FileOperation[] {
  const operations: FileOperation[] = [];
  const lines = patchText.split(/\r?\n/);

  let currentMinus: string | null = null;
  let currentPlus: string | null = null;
  let additions = 0;
  let deletions = 0;

  const flushOperation = () => {
    if (currentMinus === null && currentPlus === null) {
      return;
    }

    let operation: FileOperation;

    if (currentMinus === '/dev/null' && currentPlus && currentPlus !== '/dev/null') {
      // New file
      operation = {
        path: currentPlus,
        operation: 'created',
        additions,
        deletions,
      };
    } else if (currentPlus === '/dev/null' && currentMinus && currentMinus !== '/dev/null') {
      // Deleted file
      operation = {
        path: currentMinus,
        operation: 'deleted',
        additions,
        deletions,
      };
    } else if (currentMinus && currentPlus) {
      // Modified file (use the +++ path as canonical)
      operation = {
        path: currentPlus,
        operation: 'modified',
        additions,
        deletions,
      };
    } else {
      return;
    }

    operations.push(operation);
    currentMinus = null;
    currentPlus = null;
    additions = 0;
    deletions = 0;
  };

  for (const line of lines) {
    // Check for --- header
    const minusMatch = line.match(/^--- (?:a\/)?(.+)$/);
    if (minusMatch) {
      // Flush previous operation if starting a new file
      if (currentMinus !== null || currentPlus !== null) {
        flushOperation();
      }
      currentMinus = minusMatch[1];
      continue;
    }

    // Check for +++ header
    const plusMatch = line.match(/^\+\+\+ (?:b\/)?(.+)$/);
    if (plusMatch) {
      currentPlus = plusMatch[1];
      continue;
    }

    // Count additions and deletions (lines starting with + or - but not headers)
    if (line.startsWith('+') && !line.startsWith('+++')) {
      additions++;
    } else if (line.startsWith('-') && !line.startsWith('---')) {
      deletions++;
    }
  }

  // Flush final operation
  flushOperation();

  return operations;
}

/**
 * Extracts unique file paths from patch text.
 *
 * @param patchText - The unified diff patch text
 * @returns Array of unique file paths
 */
function extractFilePaths(patchText: string): string[] {
  const paths = new Set<string>();
  const lines = patchText.split(/\r?\n/);

  for (const line of lines) {
    // Match --- a/path or +++ b/path
    const match = line.match(/^(?:---|\+\+\+) (?:[ab]\/)?(.+)$/);
    if (match && match[1] !== '/dev/null') {
      paths.add(match[1]);
    }
  }

  return Array.from(paths);
}

/**
 * Formats a file operation for display in details.
 *
 * @param op - The file operation to format
 * @returns Formatted string like "+ src/new.ts (created)"
 */
function formatFileOperation(op: FileOperation): string {
  const shortPath = formatPath(op.path);

  switch (op.operation) {
    case 'created':
      return `+ ${shortPath} (created)`;
    case 'deleted':
      return `- ${shortPath} (removed)`;
    case 'modified': {
      const changes = `+${op.additions ?? 0} -${op.deletions ?? 0}`;
      return `M ${shortPath} (${changes})`;
    }
  }
}

/**
 * Formatter for patch tool.
 *
 * Provides formatted output for patch operations, showing:
 * - File count being patched
 * - List of affected files with operation types
 */
export const patchFormatter: ToolFormatter = {
  tools: ['patch'],

  formatArgs(args: Record<string, unknown>): FormattedOutput {
    const patchArgs = args as unknown as PatchArgs;
    const patchText = patchArgs.patch_text || '';

    // Extract files to get count
    const files = extractFilePaths(patchText);
    const fileCount = files.length;

    // Summary: "Applying patch" with file count if detectable
    const summary =
      fileCount > 0
        ? `Applying patch (${fileCount} file${fileCount === 1 ? '' : 's'})`
        : 'Applying patch';

    // Details: list of files being patched
    const details: string[] = [];
    if (files.length > 0) {
      details.push(`Files to patch:`);
      for (const file of files) {
        details.push(`  ${formatPath(file)}`);
      }
    } else {
      details.push('No files detected in patch');
    }

    return {
      summary,
      details,
    };
  },

  formatResult(result: unknown, args?: Record<string, unknown>): FormattedOutput {
    const patchArgs = (args || {}) as unknown as PatchArgs;
    const patchText = patchArgs.patch_text || '';

    // Parse operations from patch
    const operations = parsePatchOperations(patchText);

    // Check for error in result
    let isError = false;
    if (result && typeof result === 'object') {
      const obj = result as Record<string, unknown>;
      // Check for error indicators
      if (obj.error || obj.isError) {
        isError = true;
      }
      // Check content for error text
      if (Array.isArray(obj.content)) {
        for (const block of obj.content) {
          if (
            block &&
            typeof block === 'object' &&
            'text' in block &&
            typeof block.text === 'string'
          ) {
            if (block.text.toLowerCase().includes('error') || block.text.includes('failed')) {
              isError = true;
              break;
            }
          }
        }
      }
    }

    const fileCount = operations.length;

    // Summary: "N files patched" or "Failed"
    const summary = isError
      ? '\u2717 Failed'
      : `\u2713 ${fileCount} file${fileCount === 1 ? '' : 's'} patched`;

    // Details: list of affected files with operation type
    const details: string[] = [];

    if (isError) {
      details.push('\u2717 Patch failed');
    } else if (operations.length > 0) {
      for (const op of operations) {
        details.push(formatFileOperation(op));
      }
    } else {
      details.push('No file operations detected');
    }

    return {
      summary,
      details,
      isError,
    };
  },
};

export default patchFormatter;
