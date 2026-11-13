import type { SlashCommand } from "./registry.ts";

/**
 * `/hub` — the Agent Hub (also Alt+A): the focused session's task subagents.
 * (`/agents` is taken: it lists addressable named agents, not the subagents a
 * run launched.) The hub itself lives in the dock; this only opens or closes it.
 */
export const agentHubCommand: SlashCommand = {
	name: "hub",
	aliases: ["tasktree", "subagents"],
	summary: "open or close the Agent Hub: subagents, transcripts, steer and cancel",
	group: "interface",
	availableWhen: (ctx) => (ctx.ui.toggleTaskTree ? true : "no agent hub in this client"),
	run(ctx, argv) {
		if (argv.length > 0) {
			ctx.ui.notice("usage: /hub (no arguments)", "warning");
			return;
		}
		ctx.ui.toggleTaskTree!();
	},
};
