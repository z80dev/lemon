/**
 * Tests for todo formatter (todoread, todowrite).
 */

import { describe, expect, it } from 'vitest';
import { todoFormatter } from './todo.js';

describe('todoFormatter.formatArgs (todowrite)', () => {
  it('shows item count in summary', () => {
    const result = todoFormatter.formatArgs({
      todos: [
        { text: 'First task', done: false },
        { text: 'Second task', done: true },
        { text: 'Third task', done: false },
      ],
    });

    expect(result.summary).toBe('3 items');
  });

  it('handles singular item correctly', () => {
    const result = todoFormatter.formatArgs({
      todos: [{ text: 'Only task', done: false }],
    });

    expect(result.summary).toBe('1 item');
  });

  it('handles empty todos array', () => {
    const result = todoFormatter.formatArgs({
      todos: [],
    });

    expect(result.summary).toBe('0 items');
    expect(result.details).toHaveLength(0);
  });

  it('shows checkbox list in details with pending items', () => {
    const result = todoFormatter.formatArgs({
      todos: [
        { text: 'Pending task', done: false },
      ],
    });

    expect(result.details).toContain('\u2610 Pending task');
  });

  it('shows checkbox list in details with done items', () => {
    const result = todoFormatter.formatArgs({
      todos: [
        { text: 'Completed task', done: true },
      ],
    });

    expect(result.details).toContain('\u2611 Completed task');
  });

  it('shows mixed pending and done items', () => {
    const result = todoFormatter.formatArgs({
      todos: [
        { text: 'Task 1', done: false },
        { text: 'Task 2', done: true },
        { text: 'Task 3', done: false },
      ],
    });

    expect(result.details).toContain('\u2610 Task 1');
    expect(result.details).toContain('\u2611 Task 2');
    expect(result.details).toContain('\u2610 Task 3');
  });

  it('handles missing todos field', () => {
    const result = todoFormatter.formatArgs({});

    expect(result.summary).toBe('0 items');
    expect(result.details).toHaveLength(0);
  });

  it('handles non-array todos field', () => {
    const result = todoFormatter.formatArgs({
      todos: 'not an array',
    });

    expect(result.summary).toBe('0 items');
  });

  it('filters out invalid todo items', () => {
    const result = todoFormatter.formatArgs({
      todos: [
        { text: 'Valid task', done: false },
        { text: 123, done: false }, // Invalid text
        { done: true }, // Missing text
        null, // Null item
        { text: 'Another valid', done: true },
      ],
    });

    // Only valid items should be counted
    expect(result.details).toContain('\u2610 Valid task');
    expect(result.details).toContain('\u2611 Another valid');
  });

  it('truncates long todo lists', () => {
    const manyTodos = Array.from({ length: 25 }, (_, i) => ({
      text: `Task ${i + 1}`,
      done: i % 2 === 0,
    }));

    const result = todoFormatter.formatArgs({ todos: manyTodos });

    // Should be truncated to 20 lines + "more" indicator
    expect(result.details.length).toBeLessThanOrEqual(21);
    expect(result.details[result.details.length - 1]).toContain('more');
  });

  it('treats missing done as false', () => {
    const result = todoFormatter.formatArgs({
      todos: [
        { text: 'Task without done', done: undefined as unknown as boolean },
      ],
    });

    expect(result.details).toContain('\u2610 Task without done');
  });
});

describe('todoFormatter.formatResult (todoread)', () => {
  it('shows pending and done counts in summary', () => {
    const result = todoFormatter.formatResult({
      todos: [
        { text: 'Pending 1', done: false },
        { text: 'Pending 2', done: false },
        { text: 'Done 1', done: true },
      ],
    });

    expect(result.summary).toBe('2 pending, 1 done');
  });

  it('shows all pending items correctly', () => {
    const result = todoFormatter.formatResult({
      todos: [
        { text: 'Task 1', done: false },
        { text: 'Task 2', done: false },
        { text: 'Task 3', done: false },
      ],
    });

    expect(result.summary).toBe('3 pending, 0 done');
  });

  it('shows all done items correctly', () => {
    const result = todoFormatter.formatResult({
      todos: [
        { text: 'Done 1', done: true },
        { text: 'Done 2', done: true },
      ],
    });

    expect(result.summary).toBe('0 pending, 2 done');
  });

  it('shows checkbox list with pending indicator', () => {
    const result = todoFormatter.formatResult({
      todos: [{ text: 'Pending task', done: false }],
    });

    expect(result.details).toContain('\u2610 Pending task');
  });

  it('shows checkbox list with done indicator', () => {
    const result = todoFormatter.formatResult({
      todos: [{ text: 'Done task', done: true }],
    });

    expect(result.details).toContain('\u2611 Done task');
  });

  it('handles empty list', () => {
    const result = todoFormatter.formatResult({
      todos: [],
    });

    expect(result.summary).toBe('0 pending, 0 done');
    expect(result.details).toHaveLength(0);
  });

  it('handles missing todos in result', () => {
    const result = todoFormatter.formatResult({});

    expect(result.summary).toBe('0 pending, 0 done');
    expect(result.details).toHaveLength(0);
  });

  it('parses todos from content blocks', () => {
    const result = todoFormatter.formatResult({
      content: [
        {
          type: 'text',
          text: JSON.stringify({
            todos: [
              { text: 'From content', done: false },
              { text: 'Another item', done: true },
            ],
          }),
        },
      ],
    });

    expect(result.summary).toBe('1 pending, 1 done');
    expect(result.details).toContain('\u2610 From content');
    expect(result.details).toContain('\u2611 Another item');
  });

  it('filters invalid items when parsing result', () => {
    const result = todoFormatter.formatResult({
      todos: [
        { text: 'Valid', done: false },
        { text: null, done: false }, // Invalid
        { text: 'Also valid', done: true },
        123, // Not an object
      ],
    });

    expect(result.summary).toBe('1 pending, 1 done');
  });

  it('truncates long result lists', () => {
    const manyTodos = Array.from({ length: 30 }, (_, i) => ({
      text: `Task ${i + 1}`,
      done: i % 3 === 0,
    }));

    const result = todoFormatter.formatResult({ todos: manyTodos });

    expect(result.details.length).toBeLessThanOrEqual(21);
    expect(result.details[result.details.length - 1]).toContain('more');
  });

  it('handles null result gracefully', () => {
    const result = todoFormatter.formatResult(null);

    expect(result.summary).toBe('0 pending, 0 done');
  });

  it('handles non-object result gracefully', () => {
    const result = todoFormatter.formatResult('not an object');

    expect(result.summary).toBe('0 pending, 0 done');
  });

  it('ignores args parameter', () => {
    const result = todoFormatter.formatResult(
      { todos: [{ text: 'Task', done: false }] },
      { someArg: 'value' }
    );

    expect(result.summary).toBe('1 pending, 0 done');
  });
});

describe('todoFormatter metadata', () => {
  it('includes both todoread and todowrite in tools array', () => {
    expect(todoFormatter.tools).toContain('todoread');
    expect(todoFormatter.tools).toContain('todowrite');
  });
});

describe('realistic scenarios', () => {
  it('formats a project task list write', () => {
    const result = todoFormatter.formatArgs({
      todos: [
        { text: 'Set up project structure', done: true },
        { text: 'Implement core functionality', done: true },
        { text: 'Write unit tests', done: false },
        { text: 'Add documentation', done: false },
        { text: 'Review and refactor', done: false },
      ],
    });

    expect(result.summary).toBe('5 items');
    expect(result.details).toContain('\u2611 Set up project structure');
    expect(result.details).toContain('\u2611 Implement core functionality');
    expect(result.details).toContain('\u2610 Write unit tests');
    expect(result.details).toContain('\u2610 Add documentation');
    expect(result.details).toContain('\u2610 Review and refactor');
  });

  it('formats a todo list read result', () => {
    const result = todoFormatter.formatResult({
      todos: [
        { text: 'Fix bug in authentication', done: true },
        { text: 'Update dependencies', done: true },
        { text: 'Add error handling', done: false },
        { text: 'Deploy to staging', done: false },
      ],
    });

    expect(result.summary).toBe('2 pending, 2 done');
    expect(result.details[0]).toBe('\u2611 Fix bug in authentication');
    expect(result.details[1]).toBe('\u2611 Update dependencies');
    expect(result.details[2]).toBe('\u2610 Add error handling');
    expect(result.details[3]).toBe('\u2610 Deploy to staging');
  });

  it('formats an empty initial todo list', () => {
    const argsResult = todoFormatter.formatArgs({ todos: [] });
    const readResult = todoFormatter.formatResult({ todos: [] });

    expect(argsResult.summary).toBe('0 items');
    expect(readResult.summary).toBe('0 pending, 0 done');
  });

  it('formats a fully completed todo list', () => {
    const result = todoFormatter.formatResult({
      todos: [
        { text: 'Task 1', done: true },
        { text: 'Task 2', done: true },
        { text: 'Task 3', done: true },
      ],
    });

    expect(result.summary).toBe('0 pending, 3 done');
    expect(result.details.every((d) => d.includes('\u2611'))).toBe(true);
  });
});
