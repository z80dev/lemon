/**
 * Type definitions for the formatter infrastructure.
 *
 * Formatters convert tool arguments and results into human-readable
 * representations for display in the TUI.
 */

/**
 * Represents formatted output ready for display.
 */
export interface FormattedOutput {
  /** Single-line summary (for inline display) */
  summary: string;
  /** Multi-line detailed view (for expanded panel) */
  details: string[];
  /** Whether this output is considered an error */
  isError?: boolean;
}

/**
 * Interface for tool-specific formatters.
 *
 * Each formatter handles one or more tools and provides methods
 * to format arguments, results, and partial streaming results.
 */
export interface ToolFormatter {
  /** Tool name(s) this formatter handles */
  tools: string[];
  /** Format tool arguments for display */
  formatArgs(args: Record<string, unknown>): FormattedOutput;
  /** Format tool result for display */
  formatResult(result: unknown, args?: Record<string, unknown>): FormattedOutput;
  /** Format partial/streaming result */
  formatPartial?(partial: unknown, args?: Record<string, unknown>): FormattedOutput;
}
