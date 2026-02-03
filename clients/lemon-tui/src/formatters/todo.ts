/**
 * Formatter for todo tools (todoread, todowrite).
 *
 * Handles formatting of todo list arguments and results,
 * displaying tasks with checkbox indicators.
 */

import type { ToolFormatter, FormattedOutput } from './types.js';
import { truncateLines } from './base.js';

/** Maximum lines of todos to show in details */
const TODOS_MAX_LINES = 20;

/**
 * Todo item structure.
 */
interface TodoItem {
  text: string;
  done: boolean;
}

/**
 * Arguments structure for todowrite tool.
 */
interface TodoWriteArgs {
  todos: TodoItem[];
}

/**
 * Result structure from todoread tool.
 */
interface TodoReadResult {
  todos?: TodoItem[];
  content?: Array<{ type: string; text: string }>;
}

/**
 * Parses todos from a result object.
 *
 * @param result - The raw result from todoread tool
 * @returns Array of todo items
 */
function parseTodos(result: unknown): TodoItem[] {
  if (!result || typeof result !== 'object') {
    return [];
  }

  const obj = result as TodoReadResult;

  // Direct todos array
  if (Array.isArray(obj.todos)) {
    return obj.todos.filter(
      (item): item is TodoItem =>
        item !== null &&
        typeof item === 'object' &&
        typeof item.text === 'string' &&
        typeof item.done === 'boolean'
    );
  }

  // Try to parse from content if present
  if (Array.isArray(obj.content)) {
    for (const block of obj.content) {
      if (block && typeof block === 'object' && block.type === 'text' && typeof block.text === 'string') {
        try {
          const parsed = JSON.parse(block.text);
          if (Array.isArray(parsed.todos)) {
            return parsed.todos.filter(
              (item: unknown): item is TodoItem =>
                item !== null &&
                typeof item === 'object' &&
                typeof (item as TodoItem).text === 'string' &&
                typeof (item as TodoItem).done === 'boolean'
            );
          }
        } catch {
          // Not valid JSON, continue
        }
      }
    }
  }

  return [];
}

/**
 * Formats a todo item as a checkbox line.
 *
 * @param item - The todo item to format
 * @returns Formatted checkbox line
 */
function formatTodoLine(item: TodoItem): string {
  const checkbox = item.done ? '☑' : '☐';
  return `${checkbox} ${item.text}`;
}

/**
 * Counts pending and done todos.
 *
 * @param todos - Array of todo items
 * @returns Object with pending and done counts
 */
function countTodos(todos: TodoItem[]): { pending: number; done: number } {
  let pending = 0;
  let done = 0;

  for (const item of todos) {
    if (item.done) {
      done++;
    } else {
      pending++;
    }
  }

  return { pending, done };
}

/**
 * Formatter for todoread and todowrite tools.
 *
 * Provides formatted output for todo operations, showing:
 * - Summary with counts of pending/done items
 * - Checkbox list of todos in details
 */
export const todoFormatter: ToolFormatter = {
  tools: ['todoread', 'todowrite'],

  formatArgs(args: Record<string, unknown>): FormattedOutput {
    const todoArgs = args as unknown as TodoWriteArgs;
    const todos = Array.isArray(todoArgs.todos) ? todoArgs.todos : [];

    // Summary: count of items
    const summary = `${todos.length} item${todos.length === 1 ? '' : 's'}`;

    // Details: checkbox list of todos
    const details: string[] = [];
    for (const item of todos) {
      if (item && typeof item.text === 'string') {
        details.push(formatTodoLine({
          text: item.text,
          done: Boolean(item.done),
        }));
      }
    }

    return {
      summary,
      details: truncateLines(details, TODOS_MAX_LINES),
    };
  },

  formatResult(result: unknown, _args?: Record<string, unknown>): FormattedOutput {
    const todos = parseTodos(result);
    const { pending, done } = countTodos(todos);

    // Summary: count of pending and done
    const summary = `${pending} pending, ${done} done`;

    // Details: checkbox list of todos
    const details: string[] = [];
    for (const item of todos) {
      details.push(formatTodoLine(item));
    }

    return {
      summary,
      details: truncateLines(details, TODOS_MAX_LINES),
    };
  },
};

export default todoFormatter;
