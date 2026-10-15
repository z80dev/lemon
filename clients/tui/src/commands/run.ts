/**
 * Run-facing commands: aborting, retrying, the client-side queue, run listings, goals.
 *
 * The queue itself is P4's (submissions held while a run is in flight live in
 * the client, not the daemon); `/queue` here describes whatever the host
 * exposes and focuses the panel when there is one.
 */

import { ControlPlaneError, NotConnectedError } from "../protocol/errors.ts";
import { METHOD } from "../protocol/methods.ts";
import type {
	SessionRewindPreview,
	SessionRewindTarget,
	SessionTreeEntry,
} from "../protocol/session-tree.ts";
import type { Block } from "../store/transcript-model.ts";
import {
	asArray,
	humanCost,
	humanDuration,
	humanNumber,
	humanTime,
	pickBoolean,
	pickNumber,
	pickString,
} from "./format.ts";
import type { CommandContext, SlashCommand } from "./registry.ts";

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

/** `sessions.tree` server maximum page. */
const RETRY_TREE_PAGE = 500;

export const retryCommand: SlashCommand = {
	name: "retry",
	summary: "retry the last failed or aborted turn (history-only rewind, then resend)",
	usage: "[--force]",
	group: "runs",
	methods: [METHOD.sessionsTree, METHOD.sessionsRewind],
	availableWhen: (ctx) => (ctx.session.busy ? "stop the current run before retrying" : true),
	async run(ctx, argv) {
		if (argv.some((arg) => arg !== "--force") || argv.length > 1) {
			ctx.ui.notice("usage: /retry [--force] · --force also retries a completed turn", "error");
			return;
		}
		if (!ctx.ui.reloadSession || !ctx.ui.deliverPrompt) {
			ctx.ui.notice("this client cannot reload and resend a retried turn", "error");
			return;
		}
		const session = ctx.session;
		if (ctx.store.queue.items(session.key).some((item) => item.submission)) {
			ctx.ui.notice(
				"a submission outcome is unknown — inspect the session and review the queue before retrying",
				"warning",
			);
			return;
		}
		if (session.busy) {
			ctx.ui.notice("a run is in flight — /abort it first, then /retry", "warning");
			return;
		}
		const force = argv[0] === "--force";
		const outcome = session.lastRunOutcome;
		if (!force && outcome !== "error" && outcome !== "aborted") {
			ctx.ui.notice(
				outcome === "done"
					? "the last turn completed — nothing to retry (/retry --force resends it anyway)"
					: "no failed or aborted turn in this session (/retry --force resends the last prompt)",
			);
			return;
		}
		const key = session.key;
		const cwd = ctx.cwd ?? process.cwd();
		const sentLocally = lastUserText(session.blocks);

		let entry: SessionTreeEntry | undefined;
		try {
			entry = await findLastUserEntry(ctx, key, cwd);
		} catch (error) {
			retryFailure(ctx, "lookup", error);
			return;
		}
		if (!entry) {
			ctx.ui.notice("no earlier user prompt is stored for this session — nothing to retry");
			return;
		}

		const target: SessionRewindTarget = {
			sessionKey: key,
			cwd,
			entryId: entry.id,
			restoreFiles: false,
			allowPartialRestore: false,
		};
		let preview: SessionRewindPreview;
		try {
			preview = await ctx.methods.sessionsRewindPreview(target);
			if (
				preview.sessionKey !== key ||
				preview.entryId !== entry.id ||
				typeof preview.confirmationToken !== "string" ||
				preview.confirmationToken.length === 0 ||
				typeof preview.prompt !== "string" ||
				typeof preview.promptContainsNonText !== "boolean" ||
				(preview.restoreFiles !== undefined && preview.restoreFiles !== false)
			) {
				throw new Error("unexpected rewind preview");
			}
		} catch (error) {
			retryFailure(ctx, "preview", error);
			return;
		}
		if (preview.promptContainsNonText) {
			ctx.ui.notice(
				"the stored prompt contains images or other non-text content that /retry cannot resend — history is unchanged; resend the original prompt with its attachments manually",
				"warning",
			);
			return;
		}
		if (preview.prompt.trim().length === 0) {
			ctx.ui.notice(
				"the last prompt has no text to resend — use /rewind to choose another",
				"warning",
			);
			return;
		}
		// A failure before the prompt was stored leaves the stored "last prompt"
		// belonging to an earlier, finished turn. Rewinding it would resend the wrong
		// prompt, so hand the typed one back instead and change nothing.
		if (sentLocally !== undefined && normalize(sentLocally) !== normalize(preview.prompt)) {
			stageDraft(ctx, key, sentLocally);
			ctx.ui.notice(
				"the failed prompt was not stored in the session history, so there is nothing to rewind — it is back in the composer; press enter to resend",
				"warning",
			);
			return;
		}

		try {
			const result = await ctx.methods.sessionsRewindConfirm({
				...target,
				confirmationToken: preview.confirmationToken,
			});
			if (
				result.sessionKey !== key ||
				result.entryId !== entry.id ||
				result.prompt !== preview.prompt ||
				result.restoreFiles !== false ||
				result.restoredPaths.length > 0
			) {
				ctx.ui.notice(
					"retry outcome could not be verified; inspect /tree before doing anything else — nothing was resent",
					"error",
				);
				return;
			}
		} catch (error) {
			retryFailure(ctx, "rewind", error, true);
			stageDraft(ctx, key, preview.prompt);
			return;
		}

		// History is rewound; from here the prompt must not be lost. It sits in the
		// draft until the resend is acknowledged by a concrete run receipt.
		ctx.ui.resetSession?.(key);
		stageDraft(ctx, key, preview.prompt);
		try {
			await ctx.ui.reloadSession(key);
		} catch (error) {
			ctx.ui.notice(
				`rewound, but the history reload failed (${errorCode(error)}) — the prompt is in the composer; use /resume to reload, then send it`,
				"warning",
			);
			return;
		}
		if (ctx.store.focusedKey !== key) {
			ctx.ui.notice(
				"retry rewound the session, but focus moved — its prompt is parked as that session's draft",
				"warning",
			);
			return;
		}
		ctx.ui.notice(
			`retrying the last prompt · the discarded turn stays in /tree${force && outcome === "done" ? " (forced retry of a completed turn)" : ""}`,
		);
		const disposition = await ctx.ui.deliverPrompt(preview.prompt, "queue");
		if (disposition === "accepted") {
			if (ctx.store.drafts.get(key) === preview.prompt) ctx.store.setDraft(key, "");
			if (ctx.store.focusedKey === key && ctx.ui.getDraft() === preview.prompt) {
				ctx.ui.setDraft("");
			}
		}
	},
};

/** The last user-prompt text in a session's transcript, if it has one. */
function lastUserText(blocks: readonly Block[]): string | undefined {
	for (let index = blocks.length - 1; index >= 0; index--) {
		const block = blocks[index];
		if (block.kind === "user") return block.text;
	}
	return undefined;
}

function normalize(text: string): string {
	return text.replace(/\s+/g, " ").trim();
}

/** Park `text` as the session's draft, and in the editor when it is on screen. */
function stageDraft(ctx: CommandContext, key: string, text: string): void {
	ctx.store.setDraft(key, text);
	if (ctx.store.focusedKey === key) ctx.ui.setDraft(text);
}

/**
 * The newest rewindable user entry on the active branch. Entries come in
 * creation order, so the last page is read first and earlier pages only when
 * the tail holds no user prompt.
 */
async function findLastUserEntry(
	ctx: CommandContext,
	sessionKey: string,
	cwd: string,
): Promise<SessionTreeEntry | undefined> {
	const read = async (offset: number) => {
		const tree = await ctx.methods.sessionsTree({
			sessionKey,
			cwd,
			limit: RETRY_TREE_PAGE,
			offset,
		});
		if (tree.sessionKey !== sessionKey || !Array.isArray(tree.entries)) {
			throw new Error("unexpected session tree receipt");
		}
		return tree;
	};
	let tree = await read(0);
	let offset = Math.floor(Math.max(tree.totalEntries - 1, 0) / RETRY_TREE_PAGE) * RETRY_TREE_PAGE;
	if (offset > 0) tree = await read(offset);
	for (;;) {
		const found = tree.entries
			.filter((entry) => entry.role === "user" && entry.rewindable && entry.isActive)
			.at(-1);
		if (found) return found;
		if (offset === 0) return undefined;
		offset -= RETRY_TREE_PAGE;
		tree = await read(offset);
	}
}

function errorCode(error: unknown): string {
	return error instanceof ControlPlaneError || error instanceof NotConnectedError
		? error.code
		: "INVALID_RESPONSE";
}

function retryFailure(ctx: CommandContext, stage: string, error: unknown, mutation = false): void {
	const uncertain =
		mutation &&
		(!(error instanceof ControlPlaneError || error instanceof NotConnectedError) ||
			(error instanceof ControlPlaneError &&
				typeof error.details === "object" &&
				error.details !== null &&
				(error.details as Record<string, unknown>).retrySafe === false));
	ctx.ui.notice(
		`retry ${stage} did not complete (${errorCode(error)}); nothing was resent${uncertain ? ". The remote outcome is uncertain; inspect /tree before retrying." : "; no history was changed"}`,
		"error",
	);
}

function describeRun(run: unknown): string {
	const model = pickString(run, "model");
	const provider = pickString(run, "provider");
	const tokens = [
		["input", "in"],
		["output", "out"],
		["total", "total"],
	]
		.map(([key, label]) => {
			const count = pickNumber(run, `tokens.${key}`);
			return count === undefined ? undefined : `${humanNumber(count)} ${label}`;
		})
		.filter(Boolean);
	const cost = humanCost(pickNumber(run, "costUsd"));
	const error = pickString(run, "error");
	const parts = [
		pickString(run, "runId") ?? "?",
		pickString(run, "status"),
		pickString(run, "engine"),
		pickString(run, "sessionKey"),
		humanDuration(pickNumber(run, "durationMs")),
		humanTime(pickNumber(run, "startedAtMs")),
		model ? `model ${provider ? `${provider}:` : ""}${model}` : provider && `provider ${provider}`,
		tokens.length > 0 ? `tokens ${tokens.join(" / ")}` : undefined,
		pickBoolean(run, "priceKnown") === false ? "cost unknown" : cost && `cost ${cost}`,
		error ? `error: ${error}` : undefined,
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
