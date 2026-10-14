/**
 * Wire-shaped `sessions.context` receipts for the fake server and gallery.
 * Category tokens always sum to `usedTokens`, as the contract requires.
 */

type Categories = Array<[id: string, label: string, tokens: number, items: number]>;

function receipt(
	sessionKey: string,
	options: {
		live: boolean;
		overhead: "live" | "snapshot" | "unavailable";
		source: "usage" | "usage+estimate" | "estimate";
		window: number;
		estimatedTokens: number;
		categories: Categories;
		top: Array<[category: string, label: string, tokens: number]>;
		messageCount: number;
		usage?: Record<string, number>;
	},
): Record<string, unknown> {
	const { window } = options;
	const usedTokens = options.categories.reduce((sum, [, , tokens]) => sum + tokens, 0);
	const percent = (tokens: number) => Math.round((tokens / window) * 1000) / 10;
	const thresholdTokens = Math.round(window * 0.84);
	return {
		sessionKey,
		live: options.live,
		overhead: options.overhead,
		model: { provider: "anthropic", id: "claude-sonnet-4-5" },
		window,
		usedTokens,
		freeTokens: Math.max(window - usedTokens, 0),
		percentUsed: percent(usedTokens),
		source: options.source,
		estimatedTokens: options.estimatedTokens,
		autoCompaction: {
			enabled: true,
			thresholdTokens,
			reserveTokens: window - thresholdTokens,
			headroomTokens: Math.max(thresholdTokens - usedTokens, 0),
		},
		categories: options.categories.map(([id, label, tokens, items]) => ({
			id,
			label,
			tokens,
			percent: percent(tokens),
			items,
		})),
		top: options.top.map(([category, label, tokens]) => ({ category, label, tokens })),
		messageCount: options.messageCount,
		usage: options.usage,
		measuredAt: 1_755_400_000_000,
	};
}

/** A live session whose total is the provider-reported size of the latest request. */
export function reportedContextFixture(sessionKey: string): Record<string, unknown> {
	return receipt(sessionKey, {
		live: true,
		overhead: "live",
		source: "usage",
		window: 200_000,
		estimatedTokens: 41_000,
		categories: [
			["system_prompt", "System prompt", 3_200, 7],
			["tool_definitions", "Tool definitions", 9_100, 21],
			["skills", "Skills", 800, 1],
			["context_files", "Context files", 4_100, 3],
			["memory", "Memory", 600, 2],
			["user_messages", "User messages", 900, 6],
			["assistant_messages", "Assistant messages", 7_400, 12],
			["tool_results", "Tool results", 19_000, 11],
			["summaries", "Summaries", 110, 1],
		],
		top: [
			["tool_results", "read result", 9_000],
			["tool_results", "bash result", 4_200],
			["context_files", "AGENTS.md (project)", 2_500],
			["assistant_messages", "assistant reply", 1_900],
			["tool_definitions", "bash", 700],
		],
		messageCount: 42,
		usage: {
			tokens: 182_400,
			costUsd: 0.4231,
			input: 120_000,
			output: 14_500,
			cacheRead: 40_000,
			cacheWrite: 7_900,
			assistantMessages: 12,
		},
	});
}

/** A stored session with no recorded overhead profile, close to its compaction threshold. */
export function estimatedContextFixture(sessionKey: string): Record<string, unknown> {
	return receipt(sessionKey, {
		live: false,
		overhead: "unavailable",
		source: "estimate",
		window: 128_000,
		estimatedTokens: 104_300,
		categories: [
			["system_prompt", "System prompt", 0, 0],
			["tool_definitions", "Tool definitions", 0, 0],
			["skills", "Skills", 0, 0],
			["context_files", "Context files", 0, 0],
			["memory", "Memory", 0, 0],
			["user_messages", "User messages", 6_200, 31],
			["assistant_messages", "Assistant messages", 28_400, 30],
			["tool_results", "Tool results", 51_700, 58],
			["summaries", "Summaries", 3_000, 1],
			["unattributed", "System prompt and tools (not itemized)", 15_000, 0],
		],
		top: [
			["tool_results", "grep result", 12_400],
			["tool_results", "read result", 8_800],
			["assistant_messages", "assistant reply", 3_100],
		],
		messageCount: 120,
	});
}
