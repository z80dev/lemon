/**
 * The protocol → formatter translation table.
 *
 * Every engine adapter puts its own keys in `action.detail` and nothing in the
 * Elixir pipeline normalises them, so these cases pin the mapping for each
 * dialect the daemon can emit. If a formatter stops receiving what it expects,
 * a card renders placeholder noise instead of the tool's output — and that
 * failure is silent, which is exactly what these tests exist to catch.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { SessionStore } from "../../src/store/session-store.ts";
import type { ToolBlock } from "../../src/store/transcript-model.ts";
import { resetBlockIds, toToolPhase } from "../../src/store/transcript-model.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import {
	buildDiffText,
	buildToolView,
	extractToolDiff,
	isToolError,
	normalizeToolArgs,
	normalizeToolName,
	normalizeToolResult,
	resolveToolName,
	stripUnifiedHeaders,
	toolArgs,
	toolCardState,
} from "../../src/ui/tool-view.ts";

beforeEach(() => {
	resetBlockIds();
	initTheme({ colorLevel: 0 });
});

afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

/** Build a tool block the way the event controller does, through the store. */
function block(
	overrides: {
		kind?: string;
		title?: string;
		detail?: Record<string, unknown>;
		phase?: string;
		ok?: boolean | null;
		message?: string | null;
	} = {},
): ToolBlock {
	const session = new SessionStore("t");
	return session.upsertTool(
		{
			id: "a1",
			kind: overrides.kind ?? "tool",
			title: overrides.title ?? "a tool",
			detail: overrides.detail ?? null,
		},
		toToolPhase(overrides.phase ?? "started"),
		{ runId: "run-1", ok: overrides.ok ?? null, message: overrides.message ?? null },
	);
}

describe("tool name resolution", () => {
	test("reads each engine's own name key", () => {
		expect(resolveToolName(block({ detail: { name: "Bash" } }))).toBe("bash");
		expect(resolveToolName(block({ detail: { tool_name: "read" } }))).toBe("read");
		expect(resolveToolName(block({ detail: { tool: "list_issues", server: "sentry" } }))).toBe(
			"listissues",
		);
		expect(resolveToolName(block({ detail: { result_meta: { tool_name: "grep" } } }))).toBe("grep");
	});

	test("falls back to the action kind when no engine reported a name", () => {
		// Codex opens shell calls with no detail at all.
		expect(resolveToolName(block({ kind: "command" }))).toBe("bash");
		expect(resolveToolName(block({ kind: "subagent" }))).toBe("task");
		expect(resolveToolName(block({ kind: "file_change" }))).toBe("edit");
		expect(resolveToolName(block({ kind: "web_search" }))).toBe("websearch");
		expect(
			resolveToolName(block({ kind: "web_search", detail: { args: { url: "https://x" } } })),
		).toBe("webfetch");
		expect(resolveToolName(block({ kind: "note" }))).toBeUndefined();
	});

	test("normalizes casing, separators and known synonyms", () => {
		expect(normalizeToolName("Web_Search")).toBe("websearch");
		expect(normalizeToolName("MultiEdit")).toBe("multiedit");
		expect(normalizeToolName("read_file")).toBe("read");
		expect(normalizeToolName("Shell")).toBe("bash");
		expect(normalizeToolName("Agent")).toBe("task");
	});
});

describe("argument extraction", () => {
	test("finds the argument map under every engine's key", () => {
		expect(toolArgs(block({ detail: { input: { a: 1 } } }))).toEqual({ a: 1 });
		expect(toolArgs(block({ detail: { args: { a: 2 } } }))).toEqual({ a: 2 });
		expect(toolArgs(block({ detail: { arguments: { a: 3 } } }))).toEqual({ a: 3 });
		expect(toolArgs(block({}))).toEqual({});
	});

	test("fills the canonical alias the formatters read, keeping the original", () => {
		const args = normalizeToolArgs({
			file_path: "/tmp/x.ts",
			old_string: "a",
			new_string: "b",
			cmd: "ls",
			patch: "@@",
		});
		expect(args.path).toBe("/tmp/x.ts");
		expect(args.old_text).toBe("a");
		expect(args.new_text).toBe("b");
		expect(args.command).toBe("ls");
		expect(args.patch_text).toBe("@@");
		// Nothing the engine sent is dropped.
		expect(args.file_path).toBe("/tmp/x.ts");
	});

	test("never overwrites a canonical key the engine already used", () => {
		expect(normalizeToolArgs({ path: "canonical", file_path: "alias" }).path).toBe("canonical");
	});
});

describe("result extraction", () => {
	test("rebuilds the {content, details} shape from each engine's result key", () => {
		for (const detail of [
			{ result: "output" },
			{ result_preview: "output" },
			{ output_preview: "output" },
			{ result_summary: "output" },
		]) {
			const result = normalizeToolResult(block({ detail, phase: "completed", ok: true })) as {
				content: Array<{ text: string }>;
			};
			expect(result.content[0]?.text).toBe("output");
		}
	});

	test("folds result_meta, exit_code and changes into details", () => {
		const result = normalizeToolResult(
			block({
				detail: {
					result: "done",
					result_meta: { error_type: "timeout" },
					exit_code: 3,
					changes: [{ path: "a.ts", kind: "update" }],
				},
				phase: "completed",
				ok: false,
			}),
		) as { details: Record<string, unknown>; is_error: boolean };
		expect(result.details.error_type).toBe("timeout");
		expect(result.details.exit_code).toBe(3);
		expect(result.details.files).toEqual([{ path: "a.ts", kind: "update" }]);
		expect(result.is_error).toBe(true);
	});

	test("mirrors combined output onto stdout/stderr for the command formatters", () => {
		const ok = normalizeToolResult(
			block({ detail: { name: "bash", result: "hello" }, phase: "completed", ok: true }),
			"bash",
		) as { details: Record<string, unknown> };
		expect(ok.details.stdout).toBe("hello");

		const failed = normalizeToolResult(
			block({ detail: { name: "bash", result: "boom" }, phase: "completed", ok: false }),
			"bash",
		) as { details: Record<string, unknown> };
		expect(failed.details.stderr).toBe("boom");

		// Only the command family: everything else reads `content`.
		const read = normalizeToolResult(
			block({ detail: { name: "read", result: "text" }, phase: "completed", ok: true }),
			"read",
		) as { details: Record<string, unknown> };
		expect(read.details.stdout).toBeUndefined();
	});
});

describe("error detection", () => {
	test("recognises all four shapes engines use", () => {
		expect(isToolError(block({ phase: "completed", ok: false }))).toBe(true);
		expect(isToolError(block({ detail: { is_error: true } }))).toBe(true);
		expect(isToolError(block({ detail: { error: "EACCES" } }))).toBe(true);
		expect(isToolError(block({ detail: { error_message: "no server" } }))).toBe(true);
		expect(isToolError(block({ detail: { result_meta: { error_type: "timeout" } } }))).toBe(true);
	});

	test("a null error field is not an error (codex file_change always sends one)", () => {
		expect(isToolError(block({ detail: { changes: [], error: null } }))).toBe(false);
	});
});

describe("lifecycle state", () => {
	test("maps phase and ok onto the four card states", () => {
		expect(toolCardState(block({ phase: "started" }))).toBe("streaming");
		expect(toolCardState(block({ phase: "started", detail: { args: { command: "ls" } } }))).toBe(
			"running",
		);
		expect(toolCardState(block({ phase: "updated" }))).toBe("running");
		expect(toolCardState(block({ phase: "completed", ok: true }))).toBe("success");
		expect(toolCardState(block({ phase: "completed", ok: false }))).toBe("error");
		// The detail can say it failed even when the event's `ok` is absent.
		expect(toolCardState(block({ phase: "completed", detail: { is_error: true } }))).toBe("error");
	});
});

describe("diff extraction", () => {
	test("numbers removals against the old text and additions against the new", () => {
		expect(buildDiffText("a\nb", "A\nb")).toBe("-1|a\n+1|A\n 2|b");
	});

	test("an insertion advances only the new-side counter", () => {
		expect(buildDiffText("a\nb", "a\nx\nb")).toBe(" 1|a\n+2|x\n 3|b");
	});

	test("old/new string pairs become a diff, whatever the engine called them", () => {
		const diff = extractToolDiff(
			block({}),
			normalizeToolArgs({ file_path: "/tmp/a.ts", old_string: "one", new_string: "two" }),
			"edit",
		);
		expect(diff?.path).toBe("/tmp/a.ts");
		expect(diff?.text).toContain("-1|one");
		expect(diff?.text).toContain("+1|two");
	});

	test("a write's content renders as an all-addition diff", () => {
		const diff = extractToolDiff(
			block({}),
			normalizeToolArgs({ path: "a.ts", content: "x\ny" }),
			"write",
		);
		expect(diff?.text).toBe("+1|x\n+2|y");
		// `content` on a non-write tool means something else entirely.
		expect(extractToolDiff(block({}), { content: "x" }, "read")).toBeUndefined();
	});

	test("a raw unified patch keeps its hunks and loses its headers", () => {
		const patch = "diff --git a/x b/x\nindex 1..2\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new";
		expect(stripUnifiedHeaders(patch)).toBe("-old\n+new");
		expect(
			extractToolDiff(block({}), normalizeToolArgs({ patch_text: patch }), "patch")?.text,
		).toBe("-old\n+new");
	});

	test("a multiedit diffs its first edit", () => {
		const diff = extractToolDiff(
			block({}),
			{ path: "a.ts", edits: [{ old_string: "a", new_string: "b" }] },
			"multiedit",
		);
		expect(diff?.text).toContain("+1|b");
	});

	test("reasoning actions never carry a diff", () => {
		const view = buildToolView(
			block({ kind: "reasoning", detail: { reasoning: { text: "thinking" } } }),
		);
		expect(view.diff).toBeUndefined();
		expect(view.reasoning).toBe("thinking");
	});
});

describe("buildToolView", () => {
	test("routes a claude read through the read formatter", () => {
		const view = buildToolView(
			block({
				title: "read: `a.ts`",
				detail: {
					name: "Read",
					input: { file_path: "/tmp/a.ts" },
					result_preview: "line one\nline two",
				},
				phase: "completed",
				ok: true,
			}),
		);
		expect(view.toolName).toBe("read");
		expect(view.generic).toBe(false);
		expect(view.state).toBe("success");
		expect(view.body.join("\n")).toContain("line one");
	});

	test("an unknown tool falls back to the generic formatter, not an empty card", () => {
		const view = buildToolView(
			block({
				title: "sentry.list_issues",
				detail: {
					server: "sentry",
					tool: "list_issues",
					arguments: { project: "lemon" },
					result_preview: "3 issues",
				},
				phase: "completed",
				ok: true,
			}),
		);
		expect(view.generic).toBe(true);
		expect(view.summary).toContain("3 issues");
	});

	test("the streaming state renders no body at all", () => {
		const view = buildToolView(block({ phase: "started" }));
		expect(view.state).toBe("streaming");
		expect(view.summary).toBe("");
		expect(view.body).toEqual([]);
	});

	test("a failing event overrides a formatter that read success out of the args", () => {
		// write derives "✓ Updated <path>" from `content` alone; the event knows better.
		const view = buildToolView(
			block({
				detail: { name: "write", input: { filePath: "/ro/a.ts", content: "x" }, error: "EACCES" },
				phase: "completed",
				ok: false,
			}),
		);
		expect(view.isError).toBe(true);
		expect(view.summary).toBe("EACCES");
	});

	test("a completed action with no result still describes what ran", () => {
		// Codex commands report an exit code and nothing else.
		const view = buildToolView(
			block({
				kind: "command",
				title: "mix test",
				detail: { exit_code: 0, status: "completed" },
				phase: "completed",
				ok: true,
			}),
		);
		expect(view.summary.length + view.body.length).toBeGreaterThan(0);
	});

	test("the daemon's message reaches the body when no formatter mentioned it", () => {
		const view = buildToolView(
			block({
				detail: { name: "read", input: { path: "a.ts" }, result_preview: "x" },
				phase: "completed",
				ok: false,
				message: "session expired",
			}),
		);
		expect(view.body.join("\n")).toContain("session expired");
	});

	test("summaries are always a single line", () => {
		const view = buildToolView(
			block({
				detail: { name: "bash", args: { command: "ls" }, result: "a\nb\nc" },
				phase: "completed",
				ok: true,
			}),
		);
		expect(view.summary).not.toContain("\n");
	});
});
