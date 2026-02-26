/**
 * Formatter registry for tool display.
 *
 * This module provides a central registry for tool formatters that convert
 * tool arguments and results into human-readable displays for the TUI.
 */

import type { ToolFormatter, FormattedOutput } from './types.js';
import { truncateText, truncateLines, extractText, safeStringify } from './base.js';

// Import all formatters
import { bashFormatter } from './bash.js';
import { readFormatter } from './read.js';
import { editFormatter } from './edit.js';
import { grepFormatter } from './grep.js';
import { writeFormatter } from './write.js';
import { patchFormatter } from './patch.js';
import { findFormatter, globFormatter, lsFormatter } from './find.js';
import { webFetchFormatter, webSearchFormatter } from './web.js';
import { todoFormatter } from './todo.js';
import { taskFormatter } from './task.js';
import { processFormatter } from './process.js';

/** Default maximum length for single-line summaries */
const DEFAULT_SUMMARY_MAX_LENGTH = 200;

/** Default maximum lines for details view */
const DEFAULT_DETAILS_MAX_LINES = 20;

/** Default maximum characters per detail line */
const DEFAULT_DETAIL_LINE_MAX_LENGTH = 500;

/**
 * Registry that manages tool formatters.
 *
 * Provides methods to register formatters and format tool arguments/results.
 * Falls back to default JSON formatting for unregistered tools.
 */
export class FormatterRegistry {
  private formatters: Map<string, ToolFormatter> = new Map();

  /**
   * Registers a formatter for its specified tools.
   *
   * @param formatter - The formatter to register
   */
  register(formatter: ToolFormatter): void {
    for (const tool of formatter.tools) {
      this.formatters.set(tool, formatter);
    }
  }

  /**
   * Unregisters a formatter by removing all its tool mappings.
   *
   * @param formatter - The formatter to unregister
   */
  unregister(formatter: ToolFormatter): void {
    for (const tool of formatter.tools) {
      const registered = this.formatters.get(tool);
      if (registered === formatter) {
        this.formatters.delete(tool);
      }
    }
  }

  /**
   * Gets the formatter registered for a specific tool.
   *
   * @param toolName - The tool name to look up
   * @returns The registered formatter, or undefined if none
   */
  getFormatter(toolName: string): ToolFormatter | undefined {
    return this.formatters.get(toolName);
  }

  /**
   * Checks if a formatter is registered for a tool.
   *
   * @param toolName - The tool name to check
   * @returns True if a formatter is registered
   */
  hasFormatter(toolName: string): boolean {
    return this.formatters.has(toolName);
  }

  /**
   * Gets all registered tool names.
   *
   * @returns Array of registered tool names
   */
  getRegisteredTools(): string[] {
    return Array.from(this.formatters.keys());
  }

  /**
   * Formats tool arguments for display.
   *
   * Uses the registered formatter if available, otherwise falls back to default.
   *
   * @param toolName - The tool name
   * @param args - The tool arguments
   * @returns Formatted output
   */
  formatArgs(toolName: string, args: Record<string, unknown>): FormattedOutput {
    const formatter = this.getFormatter(toolName);
    if (formatter) {
      try {
        return formatter.formatArgs(args);
      } catch {
        // Fall back to default on formatter error
        return this.defaultFormatArgs(args);
      }
    }
    return this.defaultFormatArgs(args);
  }

  /**
   * Formats tool result for display.
   *
   * Uses the registered formatter if available, otherwise falls back to default.
   *
   * @param toolName - The tool name
   * @param result - The tool result
   * @param args - Optional tool arguments for context
   * @returns Formatted output
   */
  formatResult(
    toolName: string,
    result: unknown,
    args?: Record<string, unknown>
  ): FormattedOutput {
    const formatter = this.getFormatter(toolName);
    if (formatter) {
      try {
        return formatter.formatResult(result, args);
      } catch {
        // Fall back to default on formatter error
        return this.defaultFormatResult(result);
      }
    }
    return this.defaultFormatResult(result);
  }

  /**
   * Formats partial/streaming result for display.
   *
   * Uses the registered formatter if available and it supports partial formatting,
   * otherwise falls back to default result formatting.
   *
   * @param toolName - The tool name
   * @param partial - The partial result
   * @param args - Optional tool arguments for context
   * @returns Formatted output
   */
  formatPartial(
    toolName: string,
    partial: unknown,
    args?: Record<string, unknown>
  ): FormattedOutput {
    const formatter = this.getFormatter(toolName);
    if (formatter?.formatPartial) {
      try {
        return formatter.formatPartial(partial, args);
      } catch {
        // Fall back to default on formatter error
        return this.defaultFormatResult(partial);
      }
    }
    // If no partial formatter, use result formatter
    if (formatter) {
      try {
        return formatter.formatResult(partial, args);
      } catch {
        return this.defaultFormatResult(partial);
      }
    }
    return this.defaultFormatResult(partial);
  }

  /**
   * Default formatter for tool arguments.
   *
   * Produces a JSON representation, truncated for display.
   *
   * @param args - The tool arguments
   * @returns Formatted output
   */
  private defaultFormatArgs(args: Record<string, unknown>): FormattedOutput {
    if (!args || Object.keys(args).length === 0) {
      return {
        summary: '(no arguments)',
        details: [],
      };
    }

    const json = safeStringify(args);
    const summary = truncateText(json, DEFAULT_SUMMARY_MAX_LENGTH);

    // For details, format each key-value pair on its own line
    const details: string[] = [];
    for (const [key, value] of Object.entries(args)) {
      const valueStr = safeStringify(value);
      const truncatedValue = truncateText(valueStr, DEFAULT_DETAIL_LINE_MAX_LENGTH);
      details.push(`${key}: ${truncatedValue}`);
    }

    return {
      summary,
      details: truncateLines(details, DEFAULT_DETAILS_MAX_LINES),
    };
  }

  /**
   * Default formatter for tool results.
   *
   * Attempts to extract text content, falling back to JSON.
   *
   * @param result - The tool result
   * @returns Formatted output
   */
  private defaultFormatResult(result: unknown): FormattedOutput {
    // Handle null/undefined
    if (result === null || result === undefined) {
      return {
        summary: '(no result)',
        details: [],
      };
    }

    // Check for error indicator in result
    const isError = this.isErrorResult(result);

    // Try to extract text content first
    const text = extractText(result);
    if (text) {
      const lines = text.split(/\r?\n/);
      const summary = truncateText(lines[0] || '', DEFAULT_SUMMARY_MAX_LENGTH);

      return {
        summary,
        details: truncateLines(
          lines.map((line) => truncateText(line, DEFAULT_DETAIL_LINE_MAX_LENGTH)),
          DEFAULT_DETAILS_MAX_LINES
        ),
        isError,
      };
    }

    // Fall back to JSON
    const json = safeStringify(result);
    const summary = truncateText(json, DEFAULT_SUMMARY_MAX_LENGTH);
    const lines = json.split(/\r?\n/);

    return {
      summary,
      details: truncateLines(
        lines.map((line) => truncateText(line, DEFAULT_DETAIL_LINE_MAX_LENGTH)),
        DEFAULT_DETAILS_MAX_LINES
      ),
      isError,
    };
  }

  /**
   * Checks if a result appears to be an error.
   *
   * @param result - The result to check
   * @returns True if the result indicates an error
   */
  private isErrorResult(result: unknown): boolean {
    if (!result || typeof result !== 'object') {
      return false;
    }

    const obj = result as Record<string, unknown>;

    // Check common error indicators
    if (obj.is_error === true || obj.isError === true || obj.error === true) {
      return true;
    }

    // Check for error field with content
    if (typeof obj.error === 'string' && obj.error.length > 0) {
      return true;
    }

    return false;
  }
}

/**
 * Default formatter registry instance.
 *
 * Tool formatters should be registered with this instance for global use.
 */
export const defaultRegistry = new FormatterRegistry();

// Register all formatters with the default registry
defaultRegistry.register(bashFormatter);
defaultRegistry.register(readFormatter);
defaultRegistry.register(editFormatter);
defaultRegistry.register(grepFormatter);
defaultRegistry.register(writeFormatter);
defaultRegistry.register(patchFormatter);
defaultRegistry.register(findFormatter);
defaultRegistry.register(globFormatter);
defaultRegistry.register(lsFormatter);
defaultRegistry.register(webFetchFormatter);
defaultRegistry.register(webSearchFormatter);
defaultRegistry.register(todoFormatter);
defaultRegistry.register(taskFormatter);
defaultRegistry.register(processFormatter);

// Re-export types and utilities
export * from './types.js';
export * from './base.js';
