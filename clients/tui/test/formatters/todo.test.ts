/**
 * Tests for the todo formatter.
 */

import { describe, expect, it } from "bun:test";
import { todoFormatter } from "../../src/formatters/todo.js";

const todos = [
	{ id: "1", content: "Write parser", status: "completed", priority: "high" },
	{ id: "2", content: "Wire formatter", status: "in_progress", priority: "medium" },
	{ id: "3", content: "Add tests", status: "pending", priority: "low" },
];

describe("todoFormatter.formatArgs", () => {
	it("shows the items for action write, checkbox by status", () => {
		const result = todoFormatter.formatArgs({ action: "write", todos });

		expect(result.summary).toBe("write 3 items");
		expect(result.details).toEqual(["☑ Write parser (high)", "◐ Wire formatter", "☐ Add tests"]);
	});

	it("shows only the action for read/progress/actionable", () => {
		for (const action of ["read", "progress", "actionable"]) {
			const result = todoFormatter.formatArgs({ action });
			expect(result.summary).toBe(action);
			expect(result.details).toEqual([]);
		}
	});

	it("skips entries without content", () => {
		const result = todoFormatter.formatArgs({
			action: "write",
			todos: [{ id: "x", status: "pending" }, ...todos.slice(2)],
		});

		expect(result.summary).toBe("write 1 item");
		expect(result.details).toEqual(["☐ Add tests"]);
	});
});

describe("todoFormatter.formatResult", () => {
	it("reads the list from details.todos", () => {
		const result = todoFormatter.formatResult({
			content: [{ type: "text", text: JSON.stringify(todos, null, 2) }],
			details: { title: "2 todos", todos },
			is_error: false,
		});

		expect(result.summary).toBe("1 in progress, 1 pending, 1 done");
		expect(result.details).toEqual(["☑ Write parser (high)", "◐ Wire formatter", "☐ Add tests"]);
	});

	it("falls back to the JSON list in the text content", () => {
		const result = todoFormatter.formatResult({
			content: [{ type: "text", text: JSON.stringify(todos, null, 2) }],
			details: {},
			is_error: false,
		});

		expect(result.summary).toBe("1 in progress, 1 pending, 1 done");
		expect(result.details).toHaveLength(3);
	});

	it("shows progress counts for action progress", () => {
		const progress = {
			total: 4,
			completed: 1,
			in_progress: 1,
			blocked: 0,
			pending: 2,
			percentage: 25,
		};
		const result = todoFormatter.formatResult({
			content: [{ type: "text", text: JSON.stringify(progress, null, 2) }],
			details: { ...progress, title: "todo progress" },
			is_error: false,
		});

		expect(result.summary).toBe("1/4 done (25%)");
		expect(result.details).toEqual(["in progress: 1", "pending: 2"]);
	});

	it("reports an empty list", () => {
		const result = todoFormatter.formatResult({
			content: [{ type: "text", text: "[]" }],
			details: { title: "0 todos", todos: [] },
		});

		expect(result.summary).toBe("no todos");
		expect(result.details).toEqual([]);
	});

	it("preserves blocked and abandoned counts, phases and blocker notes", () => {
		const result = todoFormatter.formatResult({
			details: {
				todos: [
					{ content: "Deploy", status: "blocked", phase: "Release", blocker: "Need access" },
					{ content: "Old approach", status: "abandoned" },
				],
			},
		});
		expect(result.summary).toBe("1 blocked, 1 abandoned");
		expect(result.details).toEqual(["⊘ [Release] Deploy — blocked: Need access", "☒ Old approach"]);
		const progress = todoFormatter.formatResult({
			details: { total: 2, completed: 0, blocked: 1, abandoned: 1, percentage: 0 },
		});
		expect(progress.summary).toBe("0/2 done (0%)");
		expect(progress.details).toEqual(["blocked: 1", "abandoned: 1"]);
	});

	it("marks tool errors", () => {
		const result = todoFormatter.formatResult({
			content: [{ type: "text", text: "Todo 1 status must be pending, in_progress, or completed" }],
			details: {},
			is_error: true,
		});

		expect(result.isError).toBe(true);
		expect(result.summary).toBe("Todo 1 status must be pending, in_progress, or completed");
	});
});
