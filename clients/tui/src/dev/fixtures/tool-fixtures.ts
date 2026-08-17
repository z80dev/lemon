/**
 * Recorded-shape `tool_use` payloads, one per tool the gallery renders.
 *
 * These are written by hand against the shapes `event_bridge.ex` actually emits
 * — which is to say, against the shapes each *engine adapter* puts into
 * `action.detail`, because nothing in the Elixir pipeline normalises that map.
 * The `engine` field on each fixture records which adapter's dialect it mimics,
 * so the set as a whole is a regression net for {@link buildToolView}'s
 * translation table:
 *
 *   claude    `detail.name` (capitalised) · `detail.input` · `result_preview`
 *   codex     no tool name for shell · empty started detail · `exit_code`
 *   opencode  string keys · `detail.name` · `output_preview` · `changes`
 *   pi        `detail.tool_name` · `detail.args` · raw `result`
 *   lemon     `detail.name` (lowercase) · `detail.args` · `result` + `result_meta`
 *
 * Blocks are produced by replaying the fixture's phases through a real
 * {@link SessionStore}, so the gallery exercises the same upsert path the live
 * client does rather than hand-rolling a ToolBlock.
 */

import type { AgentAction } from "../../protocol/types.ts";
import { SessionStore } from "../../store/session-store.ts";
import type { ToolBlock } from "../../store/transcript-model.ts";
import { toToolPhase } from "../../store/transcript-model.ts";
import type { ToolCardState } from "../../ui/tool-view.ts";

export interface ToolFixture {
	/** Gallery key, matched by `--tool`. */
	name: string;
	/** Which engine adapter's `detail` dialect this fixture reproduces. */
	engine: "claude" | "codex" | "opencode" | "pi" | "lemon";
	kind: string;
	title: string;
	/** `detail` at `started`. Undefined reproduces codex's detail-less open. */
	started?: Record<string, unknown>;
	/** `detail` at `updated`, when the engine streams progress. */
	updated?: Record<string, unknown>;
	/** `detail` at a successful `completed` (engines send the merged map). */
	completed: Record<string, unknown>;
	/** `detail` at a failed `completed`. */
	failed: Record<string, unknown>;
	/** `event.message` on the failure. */
	failedMessage?: string;
}

const EDIT_OLD = `export function toolTitle(action) {
	const title = action?.title?.trim();
	if (title) return title;
	return "tool";
}`;

const EDIT_NEW = `export function toolTitle(action: AgentAction | undefined): string {
	const title = action?.title?.trim();
	if (title) return title;
	const kind = action?.kind?.trim();
	if (kind) return kind;
	return "tool";
}`;

const PATCH_TEXT = `--- a/lib/lemon/run.ex
+++ b/lib/lemon/run.ex
@@ -12,7 +12,7 @@
   def start(job) do
-    {:ok, pid} = Runner.start_link(job)
+    {:ok, pid} = Runner.start_link(job, timeout: :infinity)
     Registry.register(job.id, pid)
   end`;

export const TOOL_FIXTURES: ToolFixture[] = [
	{
		name: "bash",
		engine: "lemon",
		kind: "command",
		title: "`ls -la clients/tui`",
		started: { name: "bash", args: { command: "ls -la clients/tui", cwd: "/home/z80/dev/lemon" } },
		completed: {
			name: "bash",
			args: { command: "ls -la clients/tui", cwd: "/home/z80/dev/lemon" },
			result:
				"total 96\ndrwxr-xr-x 6 z80 z80  4096 Aug 17 00:57 .\ndrwxr-xr-x 9 z80 z80  4096 Aug 16 23:04 ..\n-rw-r--r-- 1 z80 z80   451 Aug 16 23:04 biome.json\n-rw-r--r-- 1 z80 z80  5642 Aug 16 23:04 bun.lock\ndrwxr-xr-x 8 z80 z80  4096 Aug 17 00:57 src",
			result_meta: { exit_code: 0 },
		},
		failed: {
			name: "bash",
			args: { command: "ls -la clients/tui", cwd: "/home/z80/dev/lemon" },
			result: "ls: cannot access 'clients/tui': No such file or directory",
			result_meta: { exit_code: 2, error_type: "exit_status" },
		},
		failedMessage: "command exited with status 2",
	},
	{
		name: "read",
		engine: "claude",
		kind: "tool",
		title: "read: `clients/tui/src/app.ts`",
		started: {
			name: "Read",
			input: { file_path: "/home/z80/dev/lemon/clients/tui/src/app.ts", limit: 120 },
			parent_tool_use_id: null,
		},
		completed: {
			name: "Read",
			input: { file_path: "/home/z80/dev/lemon/clients/tui/src/app.ts", limit: 120 },
			tool_use_id: "toolu_01H8s",
			result_preview:
				'     1\timport { Editor } from "@oh-my-pi/pi-tui/components/editor";\n     2\timport { Text } from "@oh-my-pi/pi-tui/components/text";\n     3\t\n     4\texport class AppShell {',
			is_error: false,
		},
		failed: {
			name: "Read",
			input: { file_path: "/home/z80/dev/lemon/clients/tui/src/missing.ts" },
			tool_use_id: "toolu_01H8s",
			result_preview: "Error: ENOENT: no such file or directory",
			is_error: true,
		},
		failedMessage: "file not found",
	},
	{
		name: "edit",
		engine: "claude",
		kind: "file_change",
		title: "clients/tui/src/store/transcript-model.ts",
		started: {
			name: "Edit",
			input: {
				file_path: "/home/z80/dev/lemon/clients/tui/src/store/transcript-model.ts",
				old_string: EDIT_OLD,
				new_string: EDIT_NEW,
			},
			parent_tool_use_id: null,
		},
		completed: {
			name: "Edit",
			input: {
				file_path: "/home/z80/dev/lemon/clients/tui/src/store/transcript-model.ts",
				old_string: EDIT_OLD,
				new_string: EDIT_NEW,
			},
			tool_use_id: "toolu_01K2p",
			result_preview: "The file has been updated.",
			is_error: false,
		},
		failed: {
			name: "Edit",
			input: {
				file_path: "/home/z80/dev/lemon/clients/tui/src/store/transcript-model.ts",
				old_string: EDIT_OLD,
				new_string: EDIT_NEW,
			},
			tool_use_id: "toolu_01K2p",
			result_preview: "Error: old_string not found in file",
			is_error: true,
		},
		failedMessage: "no match",
	},
	{
		name: "write",
		engine: "opencode",
		kind: "file_change",
		title: "clients/tui/src/ui/components/accordion.ts",
		started: {
			name: "write",
			input: {
				filePath: "/home/z80/dev/lemon/clients/tui/src/ui/components/accordion.ts",
				content:
					'export type AccordionState = "hidden" | "collapsed" | "expanded";\n\nexport function resolveAccordionState(kind) {\n\treturn KIND_DEFAULTS[kind] ?? "expanded";\n}\n',
			},
			callID: "call_9f1c",
			changes: [{ path: "clients/tui/src/ui/components/accordion.ts", kind: "update" }],
		},
		completed: {
			name: "write",
			input: {
				filePath: "/home/z80/dev/lemon/clients/tui/src/ui/components/accordion.ts",
				content:
					'export type AccordionState = "hidden" | "collapsed" | "expanded";\n\nexport function resolveAccordionState(kind) {\n\treturn KIND_DEFAULTS[kind] ?? "expanded";\n}\n',
			},
			callID: "call_9f1c",
			changes: [{ path: "clients/tui/src/ui/components/accordion.ts", kind: "update" }],
			output_preview: "Wrote 148 bytes to accordion.ts",
			exit_code: 0,
		},
		failed: {
			name: "write",
			input: { filePath: "/read-only/accordion.ts", content: "x" },
			callID: "call_9f1c",
			error: "EACCES: permission denied",
			exit_code: 1,
		},
		failedMessage: "permission denied",
	},
	{
		name: "grep",
		engine: "lemon",
		kind: "tool",
		title: "grep: upsertTool",
		started: {
			name: "grep",
			args: { pattern: "upsertTool", path: "clients/tui/src", context_lines: 1 },
		},
		completed: {
			name: "grep",
			args: { pattern: "upsertTool", path: "clients/tui/src", context_lines: 1 },
			result:
				"clients/tui/src/store/session-store.ts:159:\tupsertTool(\nclients/tui/src/ui/controllers/event-controller.ts:215:\t\t\t\tconst block = session.upsertTool(tool.action, toToolPhase(tool.phase), {\n\n2 matches in 2 files",
			result_meta: { match_count: 2 },
		},
		failed: {
			name: "grep",
			args: { pattern: "upsertTool(", path: "clients/tui/src" },
			result: "regex parse error: unclosed group",
			result_meta: { error_type: "invalid_pattern" },
		},
		failedMessage: "invalid regular expression",
	},
	{
		name: "patch",
		engine: "pi",
		kind: "file_change",
		title: "apps/lemon_gateway/lib/lemon_gateway/run.ex",
		started: { tool_name: "patch", args: { patch_text: PATCH_TEXT } },
		completed: {
			tool_name: "patch",
			args: { patch_text: PATCH_TEXT },
			result: "1 file changed, 1 insertion(+), 1 deletion(-)",
			is_error: false,
		},
		failed: {
			tool_name: "patch",
			args: { patch_text: PATCH_TEXT },
			result: "error: patch does not apply",
			is_error: true,
		},
		failedMessage: "patch does not apply",
	},
	{
		name: "find",
		engine: "lemon",
		kind: "tool",
		title: "find: *.test.ts",
		started: { name: "find", args: { pattern: "*.test.ts", path: "clients/tui/test", type: "f" } },
		completed: {
			name: "find",
			args: { pattern: "*.test.ts", path: "clients/tui/test", type: "f" },
			result:
				"clients/tui/test/ui/transcript-blocks.test.ts\nclients/tui/test/ui/tool-card.test.ts\nclients/tui/test/store/session-store.test.ts\nclients/tui/test/protocol/client.test.ts",
			result_meta: { count: 4 },
		},
		failed: {
			name: "find",
			args: { pattern: "*.test.ts", path: "/nope" },
			result: "no such directory: /nope",
			result_meta: { error_type: "enoent" },
		},
	},
	{
		name: "websearch",
		engine: "codex",
		kind: "web_search",
		title: "pi-tui differential rendering",
		started: { query: "pi-tui differential rendering" },
		completed: {
			query: "pi-tui differential rendering",
			result_preview:
				"1. oh-my-pi/pi-tui — differential terminal renderer (github.com)\n2. Terminal UI rendering strategies (blog.example.com)",
			result_summary: "2 results",
		},
		failed: {
			query: "pi-tui differential rendering",
			error_message: "search provider returned 429",
		},
		failedMessage: "rate limited",
	},
	{
		name: "webfetch",
		engine: "lemon",
		kind: "web_search",
		title: "https://omp.sh/docs/tui",
		started: { name: "webfetch", args: { url: "https://omp.sh/docs/tui", format: "markdown" } },
		completed: {
			name: "webfetch",
			args: { url: "https://omp.sh/docs/tui", format: "markdown" },
			result: "# pi-tui\n\nA differential-rendering terminal UI library for Bun.",
			result_meta: { status: 200 },
		},
		failed: {
			name: "webfetch",
			args: { url: "https://omp.sh/docs/tui" },
			result: "request timed out after 30000ms",
			result_meta: { error_type: "timeout", timeout_ms: 30000 },
		},
	},
	{
		name: "todo",
		engine: "claude",
		kind: "tool",
		title: "TodoWrite",
		started: {
			name: "TodoWrite",
			input: {
				todos: [
					{ text: "port the formatters", done: true },
					{ text: "build the tool card", done: true },
					{ text: "wire the shelf into the controller", done: false },
					{ text: "write the gallery", done: false },
				],
			},
		},
		completed: {
			name: "TodoWrite",
			input: {
				todos: [
					{ text: "port the formatters", done: true },
					{ text: "build the tool card", done: true },
					{ text: "wire the shelf into the controller", done: false },
					{ text: "write the gallery", done: false },
				],
			},
			result_preview: "Todos updated",
			is_error: false,
		},
		failed: {
			name: "TodoWrite",
			input: { todos: [] },
			result_preview: "Error: todos must not be empty",
			is_error: true,
		},
	},
	{
		name: "task",
		engine: "lemon",
		kind: "subagent",
		title: "task(codex): audit the render contract",
		started: {
			name: "task",
			args: {
				action: "run",
				description: "audit the render contract",
				prompt: "Check every component against the settled-rows rules.",
			},
		},
		updated: {
			name: "task",
			args: { action: "run", description: "audit the render contract" },
			partial_result: {
				content: [{ type: "text", text: "reading transcript-container.ts" }],
				details: {
					current_action: {
						title: "read: transcript-container.ts",
						kind: "tool",
						phase: "started",
					},
				},
			},
		},
		completed: {
			name: "task",
			args: { action: "run", description: "audit the render contract" },
			result: "No over-declared settled rows found. One risk noted in tool-shelf.ts.",
			result_meta: {
				task_id: "task_7f2",
				engine: "codex",
				status: "completed",
				current_action: { title: "audit complete", kind: "note", phase: "completed" },
			},
		},
		failed: {
			name: "task",
			args: { action: "run", description: "audit the render contract" },
			result: "subagent aborted",
			result_meta: { task_id: "task_7f2", error_type: "aborted", engine: "codex" },
		},
		failedMessage: "subagent aborted",
	},
	{
		name: "process",
		engine: "lemon",
		kind: "tool",
		title: "process: list",
		started: { name: "process", args: { action: "list" } },
		completed: {
			name: "process",
			args: { action: "list" },
			result: "proc_01  running  bun test --watch\nproc_02  exited   mix compile",
			result_meta: { count: 2 },
		},
		failed: {
			name: "process",
			args: { action: "kill", process_id: "proc_99" },
			result: "unknown process proc_99",
			result_meta: { error_type: "not_found" },
		},
	},
	{
		name: "codex-command",
		engine: "codex",
		kind: "command",
		// Codex reports shell calls with an empty detail on `started` and puts the
		// command only in the (already truncated) title.
		title: "cd ~/dev/lemon && mix test apps/lemon_core",
		started: undefined,
		completed: { exit_code: 0, status: "completed" },
		failed: { exit_code: 1, status: "completed" },
		failedMessage: "exit status 1",
	},
	{
		name: "reasoning",
		engine: "lemon",
		kind: "reasoning",
		title: "The shelf has to stay unsealed while its shape can still change…",
		started: {
			reasoning: {
				text: "The shelf has to stay unsealed while its shape can still change, because a row that reached native scrollback can never be rewritten.",
				source: "lemon_reasoning",
			},
		},
		completed: {
			reasoning: {
				text: "The shelf has to stay unsealed while its shape can still change, because a row that reached native scrollback can never be rewritten.\n\nSo: pin the live region until the barrier, then seal once.",
				source: "lemon_reasoning",
			},
		},
		failed: {
			reasoning: { text: "…", source: "lemon_reasoning" },
		},
	},
	{
		name: "unknown",
		engine: "codex",
		kind: "tool",
		// An MCP tool nothing has a formatter for: the generic card path.
		title: "sentry.list_issues",
		started: {
			server: "sentry",
			tool: "list_issues",
			status: "in_progress",
			arguments: { project: "lemon", limit: 5, query: "is:unresolved" },
		},
		completed: {
			server: "sentry",
			tool: "list_issues",
			status: "completed",
			arguments: { project: "lemon", limit: 5, query: "is:unresolved" },
			result_preview: "3 unresolved issues: LEMON-91, LEMON-88, LEMON-71",
			result_summary: "3 unresolved issues: LEMON-91, LEMON-88, LEMON-71",
		},
		failed: {
			server: "sentry",
			tool: "list_issues",
			status: "failed",
			arguments: { project: "lemon", limit: 5 },
			error_message: "MCP server 'sentry' is not connected",
		},
		failedMessage: "MCP server unavailable",
	},
];

export function fixtureByName(name: string): ToolFixture | undefined {
	return TOOL_FIXTURES.find((fixture) => fixture.name === name);
}

interface FixturePhase {
	detail: Record<string, unknown> | undefined;
	phase: string;
	ok?: boolean;
	message?: string;
}

/** The phase sequence a fixture replays to reach a given lifecycle state. */
export function fixturePhases(fixture: ToolFixture, state: ToolCardState): FixturePhase[] {
	const started: FixturePhase = { detail: fixture.started, phase: "started" };
	switch (state) {
		case "streaming":
			// The action is open and nothing about it is known yet — the window
			// between the tool being announced and its arguments arriving.
			return [{ detail: undefined, phase: "started" }];
		case "running":
			if (fixture.updated) return [started, { detail: fixture.updated, phase: "updated" }];
			// An engine that opens with no detail at all (codex shell calls) only
			// leaves the streaming window on its first `updated`.
			return fixture.started === undefined
				? [started, { detail: undefined, phase: "updated" }]
				: [started];
		case "success":
			return [started, { detail: fixture.completed, phase: "completed", ok: true }];
		case "error":
			return [
				started,
				{
					detail: fixture.failed,
					phase: "completed",
					ok: false,
					message: fixture.failedMessage,
				},
			];
	}
}

/** Replay a fixture through a real SessionStore and return the tool block. */
export function fixtureBlock(
	fixture: ToolFixture,
	state: ToolCardState,
	options: { at?: number; runId?: string } = {},
): ToolBlock {
	const session = new SessionStore("gallery");
	const runId = options.runId ?? "run-gallery";
	let block: ToolBlock | undefined;
	for (const step of fixturePhases(fixture, state)) {
		const action: AgentAction = {
			id: `action-${fixture.name}`,
			kind: fixture.kind,
			title: fixture.title,
			detail: step.detail ?? null,
		};
		block = session.upsertTool(action, toToolPhase(step.phase), {
			runId,
			ok: step.ok ?? null,
			message: step.message ?? null,
		});
	}
	if (!block) throw new Error(`fixture ${fixture.name} produced no block`);
	// A deterministic start time keeps the gallery's elapsed readings stable.
	if (options.at !== undefined) block.at = options.at;
	return block;
}
