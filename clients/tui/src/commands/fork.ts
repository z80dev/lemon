import { NotConnectedError } from "../protocol/errors.ts";
import { METHOD } from "../protocol/methods.ts";
import type { CommandContext, SlashCommand } from "./registry.ts";

/** Clone on the daemon first; opening the child must never destroy either session. */
export const forkCommand: SlashCommand = {
	name: "fork",
	summary: "branch this session (opens a Tern split when available)",
	group: "sessions",
	methods: [METHOD.sessionsFork],
	async run(ctx, argv) {
		if (argv.length > 0) {
			ctx.ui.notice("usage: /fork", "warning");
			return;
		}
		await forkSession(ctx);
	},
};

/**
 * Fork the focused session and open the child. `entryId` (from `/tree`) ends the
 * child's history at that entry instead of the current leaf.
 */
export async function forkSession(ctx: CommandContext, entryId?: string): Promise<void> {
	if (!ctx.ui.openFork) {
		ctx.ui.notice("session fork opening is unavailable in this client", "warning");
		return;
	}
	let childKey: string;
	try {
		const result = await ctx.methods.sessionsFork({
			sessionKey: ctx.session.key,
			cwd: ctx.cwd ?? process.cwd(),
			...(entryId === undefined ? {} : { entryId }),
		});
		childKey = result.sessionKey;
	} catch (error) {
		ctx.ui.notice(
			error instanceof NotConnectedError
				? "connect to the daemon before forking; nothing was queued"
				: "session fork was not confirmed; inspect /sessions before trying again",
			"error",
		);
		return;
	}
	// Announce the durable key before opening: even a pane/client failure leaves
	// an explicit recovery route and keeps the original transcript untouched.
	ctx.ui.notice(`fork created: ${childKey}`);
	try {
		await ctx.ui.openFork(childKey);
	} catch {
		ctx.ui.notice(
			`could not open fork ${childKey}; it is preserved. Recover with /session open ${childKey}`,
			"error",
		);
	}
}
