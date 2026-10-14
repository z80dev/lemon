import { InvalidContextReceiptError } from "../protocol/context-usage.ts";
import {
	ControlPlaneError,
	MethodUnavailableError,
	NotConnectedError,
	RequestTimeoutError,
} from "../protocol/errors.ts";
import { METHOD } from "../protocol/methods.ts";
import type { NoticeLevel } from "../store/transcript-model.ts";
import { sessionUsageLine } from "./format.ts";
import type { SlashCommand } from "./registry.ts";

/**
 * `/context` — the daemon's breakdown of the focused session's context window.
 *
 * A successful measurement also becomes the status-bar gauge's number, unless a
 * run completed while it was in flight (that run's usage is newer).
 */
export const contextCommand: SlashCommand = {
	name: "context",
	aliases: ["ctx"],
	summary: "show what fills the focused session's context window",
	group: "sessions",
	methods: [METHOD.sessionsContext],
	availableWhen: (ctx) => (ctx.ui.openContextPanel ? true : "no context panel in this client"),
	async run(ctx, argv) {
		if (argv.length > 0) {
			ctx.ui.notice("usage: /context (no arguments)", "warning");
			return;
		}
		const session = ctx.session;
		const usageBefore = session.usage;
		try {
			const usage = await ctx.methods.sessionsContext({
				sessionKey: session.key,
				cwd: ctx.cwd ?? process.cwd(),
			});
			if (usage.sessionKey !== session.key) throw new InvalidContextReceiptError();
			if (session.usage === usageBefore) {
				session.applyContextMeasurement(usage.usedTokens, usage.window);
				ctx.ui.refreshStatus();
			}
			if (ctx.store.focusedKey !== session.key) return;
			ctx.ui.openContextPanel!(usage);
			if (usage.usage) ctx.ui.notice(sessionUsageLine(usage.usage));
		} catch (error) {
			const [text, level] = contextFailure(error);
			ctx.ui.notice(text, level);
		}
	},
};

/** A fixed message per failure class; raw server messages and details are never shown. */
export function contextFailure(error: unknown): [string, NoticeLevel] {
	if (ControlPlaneError.is(error, "NOT_FOUND")) {
		return ["No context recorded yet — send a prompt first.", "info"];
	}
	if (ControlPlaneError.is(error, "UNAVAILABLE")) {
		return [
			"Context usage is unavailable: nothing has been measured for this session yet.",
			"warning",
		];
	}
	if (error instanceof NotConnectedError) {
		return ["Context usage needs a live daemon connection; nothing was queued.", "warning"];
	}
	if (error instanceof RequestTimeoutError) {
		return ["Context usage did not answer in time; try /context again.", "warning"];
	}
	if (error instanceof MethodUnavailableError) {
		return [`This daemon does not support ${METHOD.sessionsContext}.`, "warning"];
	}
	if (error instanceof ControlPlaneError) {
		return [`Context usage request failed (${error.code}).`, "error"];
	}
	return ["The daemon returned an unreadable context breakdown.", "error"];
}
