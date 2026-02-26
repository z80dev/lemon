/**
 * Formatter for the read tool.
 *
 * Formats file read operations showing path, line counts, and file content.
 */

import type { ToolFormatter, FormattedOutput } from './types.js';
import { formatPath, formatBytes, extractText } from './base.js';

/** Number of preview lines to show in details view */
const PREVIEW_LINES = 8;

/** Content block with text type */
interface TextContentBlock {
  type: 'text';
  text: string;
}

/** Content block with image type */
interface ImageContentBlock {
  type: 'image';
  media_type?: string;
}

/** Content block union type */
type ContentBlock = TextContentBlock | ImageContentBlock | { type: string };

/** Read tool arguments */
interface ReadArgs {
  path?: string;
  file_path?: string;
  offset?: number;
  limit?: number;
}

/** Read tool result with content array */
interface ReadResult {
  content?: ContentBlock[];
}

/**
 * Formats line numbers with proper padding.
 *
 * @param lineNumber - The line number to format
 * @param maxLineNumber - The maximum line number (for width calculation)
 * @returns Formatted line with number prefix
 */
function formatLineNumber(lineNumber: number, maxLineNumber: number): string {
  const width = String(maxLineNumber).length;
  return String(lineNumber).padStart(width, ' ');
}

/**
 * Finds the first image content block in the result.
 *
 * @param result - The tool result
 * @returns The image block if found, undefined otherwise
 */
function findImageBlock(result: unknown): ImageContentBlock | undefined {
  if (!result || typeof result !== 'object') {
    return undefined;
  }

  const obj = result as ReadResult;
  if (!Array.isArray(obj.content)) {
    return undefined;
  }

  for (const block of obj.content) {
    if (block && typeof block === 'object' && block.type === 'image') {
      return block as ImageContentBlock;
    }
  }

  return undefined;
}

/**
 * Checks if result contains only image content (no text).
 *
 * @param result - The tool result
 * @returns True if result contains only image content
 */
function isImageOnlyResult(result: unknown): boolean {
  if (!result || typeof result !== 'object') {
    return false;
  }

  const obj = result as ReadResult;
  if (!Array.isArray(obj.content)) {
    return false;
  }

  const hasImage = obj.content.some(
    (block) => block && typeof block === 'object' && block.type === 'image'
  );
  const hasText = obj.content.some(
    (block) =>
      block &&
      typeof block === 'object' &&
      block.type === 'text' &&
      typeof (block as TextContentBlock).text === 'string' &&
      (block as TextContentBlock).text.trim().length > 0
  );

  return hasImage && !hasText;
}

/**
 * Formatter for the read tool.
 *
 * Handles formatting of file read arguments and results, including
 * text files with line numbers and image files.
 */
export const readFormatter: ToolFormatter = {
  tools: ['read'],

  formatArgs(args: Record<string, unknown>): FormattedOutput {
    const typedArgs = args as ReadArgs;
    const path = typedArgs.path || typedArgs.file_path || '';
    const formattedPath = formatPath(path);

    // Build range suffix if offset/limit specified
    let rangeSuffix = '';
    if (typedArgs.offset !== undefined || typedArgs.limit !== undefined) {
      const parts: string[] = [];
      if (typedArgs.offset !== undefined) {
        parts.push(`offset=${typedArgs.offset}`);
      }
      if (typedArgs.limit !== undefined) {
        parts.push(`limit=${typedArgs.limit}`);
      }
      rangeSuffix = ` (${parts.join(', ')})`;
    }

    const summary = formattedPath + rangeSuffix;

    return {
      summary,
      details: [summary],
    };
  },

  formatResult(result: unknown, args?: Record<string, unknown>): FormattedOutput {
    // Handle image-only results
    if (isImageOnlyResult(result)) {
      const imageBlock = findImageBlock(result);
      const mimeType = imageBlock?.media_type || 'image';

      return {
        summary: `[Image: ${mimeType}]`,
        details: [`[Image content - ${mimeType}]`],
      };
    }

    // Handle text content
    const text = extractText(result);
    if (!text) {
      // Check if there's an image mixed with empty text
      const imageBlock = findImageBlock(result);
      if (imageBlock) {
        const mimeType = imageBlock.media_type || 'image';
        return {
          summary: `[Image: ${mimeType}]`,
          details: [`[Image content - ${mimeType}]`],
        };
      }

      return {
        summary: '(empty file)',
        details: [],
      };
    }

    const lines = text.split(/\r?\n/);
    const lineCount = lines.length;
    const byteSize = new TextEncoder().encode(text).length;

    // Calculate starting line number (accounting for offset)
    const typedArgs = args as ReadArgs | undefined;
    const startLine = (typedArgs?.offset ?? 0) + 1;

    // Build summary
    const summary = `${lineCount} lines, ${formatBytes(byteSize)}`;

    // Build details with line numbers
    const details: string[] = [];
    const previewCount = Math.min(PREVIEW_LINES, lineCount);
    const maxLineNumber = startLine + previewCount - 1;

    for (let i = 0; i < previewCount; i++) {
      const lineNumber = startLine + i;
      const lineContent = lines[i] ?? '';
      const formattedNumber = formatLineNumber(lineNumber, maxLineNumber);
      details.push(`${formattedNumber}| ${lineContent}`);
    }

    // Add "more lines" indicator if truncated
    if (lineCount > PREVIEW_LINES) {
      const remaining = lineCount - PREVIEW_LINES;
      details.push(`... (${remaining} more lines)`);
    }

    return {
      summary,
      details,
    };
  },
};

export default readFormatter;
