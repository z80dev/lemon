/**
 * Run-facing commands: aborting, the client-side queue, run listings, goals.
 *
 * The queue itself is P4's (submissions held while a run is in flight live in
 * the client, not the daemon); `/queue` here describes whatever the host
 * exposes and focuses the panel when there is one.
 */

import { METHOD } from "../protocol/methods.ts";
import { asArray, humanDuration, humanTime, pickNumber, pickString } from "./format.ts";
import type { SlashCommand } from "./registry.ts";

export const abortCommand: SlashCommand = {
	name: "abort",
	aliases: ["stop"],
	summary: "stop the run in flight",
	group: "runs",
	methods: [METHOD.chatAbort],
	async run(ctx) {
		const runId = ctx.session.activeRunId;
		if (!runId) {
			ctx.ui.notice("nothing is running");
			return;
		}
		const result = await ctx.methods.chatAbort({ runId, sessionKey: ctx.session.key });
		if (result?.aborted === false) {
			ctx.ui.notice(`run ${runId} was already done`);
			return;
		}
		// A stopped run keeps the text it produced; the marker says the rest is
		// missing because the user said so, not because the model stopped there.
		ctx.ui.markInterrupted?.(runId);
		ctx.ui.notice(`aborted ${runId}`);
	},
};

export const queueCommand: SlashCommand = {
	name: "queue",
	aliases: ["q"],
	summary: "queue a prompt, or show prompts waiting for the current run",
	usage: "[prompt]",
	group: "runs",
	async run(ctx) {
		if (ctx.rest) {
			if (!ctx.ui.deliverPrompt) {
				ctx.ui.notice("this build cannot submit a queued prompt", "warning");
				return;
			}
			await ctx.ui.deliverPrompt(ctx.rest, "queue");
			return;
		}
		const queued = ctx.ui.queuedPrompts?.() ?? [];
		const parked = ctx.client.queued.filter((entry) => entry.method === METHOD.chatSend);
		if (queued.length === 0 && parked.length === 0) {
			ctx.ui.notice(`queue is empty (mode: ${ctx.store.submissionMode})`);
			return;
		}
		// The panel already lists them, editably. Printing the same lines into the
		// transcript on top of that would be a duplicate the user has to scroll past.
		if (ctx.ui.focusQueue?.()) return;
		const lines = [`queue — mode ${ctx.store.submissionMode}`];
		for (const [index, text] of queued.entries()) lines.push(`${index + 1}. ${oneLine(text)}`);
		for (const entry of parked) {
			const prompt = pickString(entry.params, "prompt") ?? "";
			lines.push(`(offline) ${oneLine(prompt)}`);
		}
		ctx.ui.noticeBlock(lines);
	},
};

export const steerCommand: SlashCommand = {
	name: "steer",
	summary: "send guidance into the active run",
	usage: "<prompt>",
	group: "runs",
	async run(ctx) {
		if (!ctx.rest) {
			ctx.ui.notice("usage: /steer <prompt>", "error");
			return;
		}
		if (!ctx.ui.deliverPrompt) {
			ctx.ui.notice("this build cannot submit steering guidance", "warning");
			return;
		}
		await ctx.ui.deliverPrompt(ctx.rest, "steer");
	},
};

export const redirectCommand: SlashCommand = {
	name: "redirect",
	summary: "replace the active run's pending direction",
	usage: "<prompt>",
	group: "runs",
	async run(ctx) {
		if (!ctx.rest) {
			ctx.ui.notice("usage: /redirect <prompt>", "error");
			return;
		}
		if (!ctx.ui.deliverPrompt) {
			ctx.ui.notice("this build cannot submit redirect guidance", "warning");
			return;
		}
		await ctx.ui.deliverPrompt(ctx.rest, "redirect");
	},
};

export const runsCommand: SlashCommand = {
	name: "runs",
	summary: "list active and recent runs",
	usage: "[count]",
	group: "runs",
	availableWhen(ctx) {
		if (ctx.methods.supports(METHOD.runsActiveList)) return true;
		if (ctx.methods.supports(METHOD.runsRecentList)) return true;
		return "daemon exposes neither runs.active.list nor runs.recent.list";
	},
	async run(ctx, argv) {
		const requested = Number.parseInt(argv[0] ?? "", 10);
		const limit = Number.isFinite(requested) && requested > 0 ? Math.min(requested, 50) : 10;
		const lines: string[] = [];

		if (ctx.methods.supports(METHOD.runsActiveList)) {
			const active = await ctx.methods.runsActiveList({ limit });
			const runs = asArray((active as { runs?: unknown })?.runs);
			lines.push(`active runs: ${runs.length}`);
			for (const run of runs) lines.push(`  ${describeRun(run)}`);
		}
		if (ctx.methods.supports(METHOD.runsRecentList)) {
			const recent = await ctx.methods.runsRecentList({ limit });
			const runs = asArray((recent as { runs?: unknown })?.runs);
			lines.push(`recent runs: ${runs.length}`);
			for (const run of runs) lines.push(`  ${describeRun(run)}`);
		}
		ctx.ui.noticeBlock(lines);
	},
};

function describeRun(run: unknown): string {
	const parts = [
		pickString(run, "runId") ?? "?",
		pickString(run, "status"),
		pickString(run, "engine"),
		pickString(run, "sessionKey"),
		humanDuration(pickNumber(run, "durationMs")),
		humanTime(pickNumber(run, "startedAtMs")),
	].filter(Boolean);
	return parts.join(" · ");
}

export const goalCommand: SlashCommand = {
	name: "goal",
	summary: "standing objective for this session",
	usage: "<set <text> | status | pause | resume | clear>",
	group: "runs",
	availableWhen(ctx) {
		return ctx.methods.supports(METHOD.goalStatus) || ctx.methods.supports(METHOD.goalSet)
			? true
			: "daemon does not expose the goal methods";
	},
	async run(ctx, argv) {
		const action = (argv[0] ?? "status").toLowerCase();
		const sessionKey = ctx.session.key;
		switch (action) {
			case "set": {
				// Everything after the verb is the objective, spaces and all.
				const objective = ctx.rest.slice(ctx.rest.indexOf(argv[0]) + argv[0].length).trim();
				if (!objective) {
					ctx.ui.notice("usage: /goal set <objective>", "error");
					return;
				}
				await ctx.methods.goalSet({ sessionKey, objective });
				ctx.ui.notice(`goal set for ${sessionKey}`);
				return;
			}
			case "status": {
				const result = await ctx.methods.goalStatus({ sessionKey });
				const goals = asArray((result as { goals?: unknown })?.goals);
				const single = (result as { goal?: unknown })?.goal;
				const rows = goals.length > 0 ? goals : single ? [single] : [];
				if (rows.length === 0) {
					ctx.ui.notice(`no goal for ${sessionKey}`);
					return;
				}
				const lines = [`goals for ${sessionKey}`];
				for (const goal of rows) {
					lines.push(
						[
							pickString(goal, "status") ?? "?",
							`${pickNumber(goal, "objectiveBytes") ?? 0}b objective`,
							`${pickNumber(goal, "continuationCount") ?? 0} continuation(s)`,
							pickString(goal, "lastRunId"),
							humanTime(pickNumber(goal, "updatedAtMs")),
						]
							.filter(Boolean)
							.join(" · "),
					);
				}
				ctx.ui.noticeBlock(lines);
				return;
			}
			case "pause":
				await ctx.methods.goalPause({ sessionKey });
				ctx.ui.notice("goal paused");
				return;
			case "resume":
				await ctx.methods.goalResume({ sessionKey });
				ctx.ui.notice("goal resumed");
				return;
			case "clear":
				await ctx.methods.goalClear({ sessionKey });
				ctx.ui.notice("goal cleared");
				return;
			default:
				ctx.ui.notice(`usage: /goal ${goalCommand.usage}`, "error");
		}
	},
};

function oneLine(text: string, max = 90): string {
	const flat = text.replace(/\s+/g, " ").trim();
	return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
}
