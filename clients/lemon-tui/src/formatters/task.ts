/**
 * Formatter for task tool results.
 *
 * Handles formatting of task execution arguments and results,
 * including engine info, current action, and nested tool info.
 */

import type { ToolFormatter, FormattedOutput } from './types.js';
import { truncateText, truncateLines } from './base.js';

/** Maximum length for prompt preview in summary */
const PROMPT_SUMMARY_MAX_LENGTH = 60;

/** Maximum lines of details to show */
const DETAILS_MAX_LINES = 15;

/**
 * Arguments structure for task tool.
 */
interface TaskArgs {
  action: 'run' | 'poll' | 'join';
  prompt?: string;
  description?: string;
  task_id?: string;
}

/**
 * Current action structure in task details.
 */
interface CurrentAction {
  title?: string;
  kind?: string;
  phase?: 'started' | 'completed' | string;
  tool?: string;
  tool_input?: Record<string, unknown>;
}

/**
 * Task details structure in result.
 */
interface TaskDetails {
  engine?: string;
  current_action?: CurrentAction;
  status?: string;
  output?: string;
}

/**
 * Result structure from task tool.
 */
interface TaskResult {
  details?: TaskDetails;
  content?: Array<{ type: string; text: string }>;
}

/**
 * Parses task details from a result object.
 *
 * @param result - The raw result from task tool
 * @returns Parsed task details
 */
function parseTaskDetails(result: unknown): TaskDetails | null {
  if (!result || typeof result !== 'object') {
    return null;
  }

  const obj = result as TaskResult;

  // Direct details object
  if (obj.details && typeof obj.details === 'object') {
    return obj.details;
  }

  // Try to parse from content if present
  if (Array.isArray(obj.content)) {
    for (const block of obj.content) {
      if (block && typeof block === 'object' && block.type === 'text' && typeof block.text === 'string') {
        try {
          const parsed = JSON.parse(block.text);
          if (parsed.details && typeof parsed.details === 'object') {
            return parsed.details;
          }
        } catch {
          // Not valid JSON, continue
        }
      }
    }
  }

  return null;
}

/**
 * Gets the phase indicator for an action.
 *
 * @param phase - The action phase
 * @returns Phase indicator string
 */
function getPhaseIndicator(phase?: string): string {
  switch (phase) {
    case 'completed':
      return '✓';
    case 'started':
    default:
      return '▶';
  }
}

/**
 * Formats the current action with phase indicator.
 *
 * @param action - The current action
 * @returns Formatted action string
 */
function formatCurrentAction(action: CurrentAction): string {
  const indicator = getPhaseIndicator(action.phase);
  const title = action.title || action.kind || 'processing';
  const suffix = action.phase === 'completed' ? '' : '...';
  return `${indicator} ${title}${suffix}`;
}

/**
 * Formats nested tool information.
 *
 * @param action - The current action with tool info
 * @returns Formatted nested tool string, or null if no tool
 */
function formatNestedTool(action: CurrentAction): string | null {
  if (!action.tool) {
    return null;
  }

  let toolInfo = action.tool;

  // Add brief input description if available
  if (action.tool_input && typeof action.tool_input === 'object') {
    const keys = Object.keys(action.tool_input);
    if (keys.length > 0) {
      const firstKey = keys[0];
      const firstValue = action.tool_input[firstKey];
      if (typeof firstValue === 'string') {
        const preview = truncateText(firstValue, 30);
        toolInfo += `: ${preview}`;
      }
    }
  }

  return `  └─ ${toolInfo}`;
}

/**
 * Formatter for task tool.
 *
 * Provides formatted output for task operations, showing:
 * - Engine and current action in summary
 * - Detailed engine info and action phases
 * - Nested tool information when available
 */
export const taskFormatter: ToolFormatter = {
  tools: ['task'],

  formatArgs(args: Record<string, unknown>): FormattedOutput {
    const taskArgs = args as unknown as TaskArgs;
    const action = taskArgs.action || 'run';

    // Get prompt/description preview
    const promptText = taskArgs.prompt || taskArgs.description || '';
    const promptPreview = promptText
      ? truncateText(promptText.replace(/\s+/g, ' ').trim(), PROMPT_SUMMARY_MAX_LENGTH)
      : '';

    // Summary: action with prompt preview
    const summary = promptPreview ? `${action}: ${promptPreview}` : action;

    // Details: action and full prompt
    const details: string[] = [];
    details.push(`action: ${action}`);

    if (taskArgs.task_id) {
      details.push(`task_id: ${taskArgs.task_id}`);
    }

    if (promptText) {
      details.push('');
      const promptLines = promptText.split(/\r?\n/);
      details.push(...truncateLines(promptLines, 10));
    }

    return {
      summary,
      details: truncateLines(details, DETAILS_MAX_LINES),
    };
  },

  formatResult(result: unknown, _args?: Record<string, unknown>): FormattedOutput {
    const taskDetails = parseTaskDetails(result);

    if (!taskDetails) {
      return {
        summary: 'completed',
        details: [],
      };
    }

    const engine = taskDetails.engine || 'unknown';
    const currentAction = taskDetails.current_action;
    const actionTitle = currentAction?.title || currentAction?.kind || 'idle';

    // Summary: engine + current action title
    const summary = `${engine}: ${actionTitle}`;

    // Details: engine info and action phases
    const details: string[] = [];
    details.push(`engine: ${engine}`);

    if (taskDetails.status) {
      details.push(`status: ${taskDetails.status}`);
    }

    if (currentAction) {
      details.push(formatCurrentAction(currentAction));

      const nestedTool = formatNestedTool(currentAction);
      if (nestedTool) {
        details.push(nestedTool);
      }
    }

    if (taskDetails.output) {
      details.push('');
      const outputLines = taskDetails.output.split(/\r?\n/);
      details.push(...truncateLines(outputLines, 5));
    }

    return {
      summary,
      details: truncateLines(details, DETAILS_MAX_LINES),
    };
  },

  formatPartial(partial: unknown, args?: Record<string, unknown>): FormattedOutput {
    // Partial formatting uses the same logic as result formatting
    return this.formatResult(partial, args);
  },
};

export default taskFormatter;
