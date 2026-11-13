import { METHOD } from "../protocol/methods.ts";
import { AgentHubComponent } from "../ui/components/agent-hub.ts";
import type { SlashCommand } from "./registry.ts";

/** The server's cap on one `chat.history` page. */
const TRANSCRIPT_LIMIT = 200;

/**
 * `/hub` — omp's Agent Hub for Lemon's children. (`/agents` is taken: it lists
 * addressable named agents, not the subagents a run launched.)
 *
 * The table is pinned to the session focused at dispatch and follows its task
 * tree live. A transcript is the child's own `chat.history` (`childSessionId`
 * under the parent's key); without that method the hub still lists children, and
 * the transcript view says why it is empty.
 */
export const agentHubCommand: SlashCommand = {
	name: "hub",
	aliases: ["subagents"],
	summary: "open the live subagent hub: status table and child transcripts",
	group: "interface",
	availableWhen: (ctx) =>
		ctx.ui.presentOverlay && ctx.ui.taskFeed ? true : "no overlay host in this client",
	run(ctx, argv) {
		if (argv.length > 0) {
			ctx.ui.notice("usage: /hub (no arguments)", "warning");
			return;
		}
		const feed = ctx.ui.taskFeed!(ctx.session.key);
		const parentKey = ctx.session.key;
		const methods = ctx.methods;
		ctx.ui.presentOverlay!(
			(host) =>
				new AgentHubComponent({
					feed,
					loadTranscript: methods.supports(METHOD.chatHistory)
						? async (row) => {
								const history = await methods.chatHistory({
									// The daemon resolves the child under the parent's key, which is also
									// its authorization scope; a child id alone is never a session key.
									sessionKey: parentKey,
									childSessionId: row.sessionId!,
									limit: TRANSCRIPT_LIMIT,
									includeFullText: true,
								});
								// A daemon that ignores childSessionId answers with the parent's history.
								if (history.childSessionId !== row.sessionId) {
									throw new Error("this daemon cannot read child transcripts — update Lemon");
								}
								return history.messages ?? [];
							}
						: undefined,
					rows: host.rows,
					close: host.close,
					repaint: host.repaint,
				}),
		);
	},
};
