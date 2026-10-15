/**
 * Recorded-shape omp delegate payloads: `session_wire` and `discovered_wire`
 * rows as `LemonOmp` projects them (camelCase string keys), for the fake
 * control plane, the gallery's `omp` tool card, and tests.
 *
 * One fixture deliberately carries terminal escape sequences in omp-owned
 * text, so every renderer's sanitization is exercised offline.
 */

/** Fixed clock so fixture ages are stable. */
export const OMP_FIXTURE_NOW = 1_791_939_500_000;

export type OmpWire = Record<string, unknown>;

export function ompSessionWire(overrides: OmpWire = {}): OmpWire {
	return {
		id: "omp_3f9a1c2b7d4e",
		ompSessionId: "01a137e9-4e60-73f4-a776-ece03008a9fe",
		title: "Fix the flaky reconnect test",
		cwd: "/work/lemon",
		model: "deepseek/deepseek-v4-flash",
		thinking: "low",
		approvalMode: "write",
		pendingApprovals: [
			{
				id: "approval_omp_1",
				tool: "bash",
				details: "git status",
				requestedAt: OMP_FIXTURE_NOW - 1_000,
			},
		],
		approvals: { approved: 2, denied: 1, expired: 0 },
		worktree: {
			path: "/work/lemon/.worktrees/omp-fix",
			branch: "omp/fix",
			base: "main",
			repo: "/work/lemon",
			kept: true,
			dirty: true,
			commits: 1,
		},
		owner: { kind: "operator" },
		status: "running",
		lastTurn: null,
		activity: "Running bash — bun test test/protocol/ws.test.ts",
		startedAt: OMP_FIXTURE_NOW - 95_000,
		updatedAt: OMP_FIXTURE_NOW - 1_000,
		endedAt: null,
		turns: 3,
		toolCalls: 5,
		activeTools: [
			{
				id: "call_9",
				name: "bash",
				intent: "Re-running the reconnect suite",
				startedAt: OMP_FIXTURE_NOW - 4_000,
			},
		],
		recentTools: [
			{ name: "read", intent: "Reading ws.ts", isError: false, durationMs: 4 },
			{ name: "edit", intent: "Raising the backoff floor", isError: false, durationMs: 11 },
			{ name: "bash", intent: "First test run", isError: true, durationMs: 2_310 },
		],
		todos: [
			{ phase: "Investigate", content: "Reproduce the flake", status: "completed" },
			{ phase: "Investigate", content: "Find the racing timer", status: "completed" },
			{ phase: "Fix", content: "Make the watchdog deterministic", status: "in_progress" },
			{ phase: "Fix", content: "Run the suite 20 times", status: "pending" },
		],
		subagents: [
			{
				id: "Explore1",
				agent: "explore",
				status: "completed",
				description: "Map timer usage",
				activity: "Finished reading timers",
				toolCalls: 3,
				recentTools: [],
				model: "provider/free",
				durationMs: 1200,
				output: "Found the timer race",
			},
		],
		usage: {
			input: 8_770,
			output: 712,
			cacheRead: 31_744,
			cacheWrite: 0,
			totalTokens: 41_226,
			cost: 0.0018,
		},
		contextPercent: 18.4,
		lastText: "The watchdog window races the first tick; making it start after the handshake.",
		result: null,
		error: null,
		declinedPrompts: 0,
		exit: null,
		...overrides,
	};
}

export const OMP_SESSION_FIXTURES: readonly OmpWire[] = [
	ompSessionWire(),
	ompSessionWire({
		id: "omp_8c21aa90e5f1",
		ompSessionId: "01a13800-2222-7000-8000-000000000002",
		title: "Summarise the release notes",
		status: "idle",
		lastTurn: "completed",
		activity: null,
		activeTools: [],
		startedAt: OMP_FIXTURE_NOW - 600_000,
		updatedAt: OMP_FIXTURE_NOW - 420_000,
		todos: [],
		subagents: [],
		result: "Release 2026.10.2 adds omp delegates, plan mode and the /context panel.",
		lastText: "Release 2026.10.2 adds omp delegates, plan mode and the /context panel.",
	}),
	ompSessionWire({
		id: "omp_51be0c7d3a08",
		ompSessionId: "01a13800-3333-7000-8000-000000000003",
		// Untrusted text with embedded escapes: renderers must show it inert.
		title: "Hostile \u001b]0;pwned\u0007title\u001b[31m red",
		status: "failed",
		lastTurn: "error",
		activity: null,
		activeTools: [],
		startedAt: OMP_FIXTURE_NOW - 900_000,
		updatedAt: OMP_FIXTURE_NOW - 880_000,
		endedAt: OMP_FIXTURE_NOW - 880_000,
		todos: [],
		subagents: [],
		error: "provider error\u001b[2J: rate limited",
		lastText: null,
		declinedPrompts: 1,
		exit: { code: 1, reason: "crashed" },
	}),
];

export const OMP_DISCOVERED_FIXTURES: readonly OmpWire[] = [
	{
		ompSessionId: "01a13700-aaaa-7000-8000-00000000000a",
		title: "Port the CLI to Bun",
		cwd: "/work/lemon",
		createdAt: OMP_FIXTURE_NOW - 86_400_000,
		updatedAt: OMP_FIXTURE_NOW - 3_600_000,
		model: "anthropic/claude-sonnet-4-5",
		lastStatus: "completed",
		activeElsewhere: false,
		liveId: null,
		source: "omp",
		interrupted: false,
		worktree: null,
	},
	{
		ompSessionId: "01a137e9-4e60-73f4-a776-ece03008a9fe",
		title: "Fix the flaky reconnect test",
		cwd: "/work/lemon",
		createdAt: OMP_FIXTURE_NOW - 95_000,
		updatedAt: OMP_FIXTURE_NOW - 1_000,
		model: "deepseek/deepseek-v4-flash",
		lastStatus: "interrupted",
		activeElsewhere: false,
		liveId: "omp_3f9a1c2b7d4e",
		source: "lemon",
		interrupted: true,
		worktree: { path: "/work/lemon/.worktrees/omp-fix", branch: "omp/fix" },
	},
];
