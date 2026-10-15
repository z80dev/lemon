/**
 * `/omp`: external omp (oh-my-pi) delegate sessions the daemon runs.
 *
 *   /omp                open the omp panel (Alt+M)
 *   /omp run <prompt>   start a delegate in the TUI's working directory
 *   /omp status         one notice summarising live and recent sessions
 *
 * Every mutation goes to the daemon or fails visibly: nothing is parked while
 * offline, a refusal is reported as one, and a request that timed out is an
 * unknown outcome rather than a failure (or a success) — the user is told to
 * refresh before retrying. omp-originated text is sanitized before display.
 */

import { basename } from "node:path";
import { safeLine } from "../formatters/base.ts";
import {
	OMP_STATUS_GLYPHS,
	ompSessionLabel,
	ompStatusText,
	ompUsageText,
} from "../formatters/omp.ts";
import {
	ControlPlaneError,
	MethodUnavailableError,
	NotConnectedError,
	RequestTimeoutError,
} from "../protocol/errors.ts";
import { type ControlPlaneMethods, METHOD, OMP_METHODS } from "../protocol/methods.ts";
import {
	isOmpSessionBusy,
	isOmpSessionEnded,
	type OmpApprovalMode,
	type OmpSession,
} from "../protocol/omp.ts";
import type { OmpStore } from "../store/omp-store.ts";
import type { CommandContext, SlashCommand } from "./registry.ts";

/** Rows one `omp.sessions.list` asks for (the server clamps to 100). */
export const OMP_LIST_LIMIT = 50;

const USAGE =
	"usage: /omp [run [--approval-mode always-ask|write|yolo] [--isolate] <prompt> | status]";

/** Why omp cannot be used through this daemon, or undefined when it can. */
export function ompUnavailableReason(
	methods: Pick<ControlPlaneMethods, "supports">,
	store: OmpStore,
): string | undefined {
	if (!OMP_METHODS.some((method) => methods.supports(method))) {
		return "this daemon does not expose the omp.* methods";
	}
	const status = store.status;
	if (status && !status.available) {
		return status.reason === "not_installed" || !status.reason
			? "omp is not installed on the daemon host"
			: `omp is unavailable (${safeLine(status.reason, 40)})`;
	}
	return undefined;
}

/**
 * A failed omp request in words the user can act on. A timed-out or
 * `retrySafe: false` mutation may already have taken effect.
 */
export function describeOmpError(error: unknown): string {
	if (error instanceof NotConnectedError) return "offline — not sent; reconnect and retry";
	if (error instanceof MethodUnavailableError) {
		return `this daemon does not support ${error.method}`;
	}
	if (error instanceof RequestTimeoutError) {
		return `no reply within ${Math.round(error.timeoutMs / 1000)}s — outcome unknown; refresh before retrying`;
	}
	if (ControlPlaneError.is(error)) {
		const message = safeLine(error.message, 200);
		const details = error.details as
			| { retrySafe?: unknown; code?: unknown; applied?: unknown; failedStep?: unknown }
			| null
			| undefined;
		if (details?.code === "OMP_PARTIALLY_APPLIED") {
			return `${message} — partially applied (${Array.isArray(details.applied) ? details.applied.join(", ") : "unknown"}); failed at ${String(details.failedStep ?? "unknown")}; refresh before changing settings again`;
		}
		if (details?.retrySafe === false) {
			return `${message} — outcome unknown; refresh before retrying`;
		}
		return message || error.code;
	}
	return safeLine(error instanceof Error ? error.message : String(error), 200);
}

/**
 * Re-read `omp.status` and `omp.sessions.list` into the store. Each read is
 * independent; a failure is returned (never thrown) so callers decide whether
 * it is worth a notice.
 */
export async function syncOmp(
	methods: ControlPlaneMethods,
	store: OmpStore,
): Promise<string | undefined> {
	const problems: string[] = [];
	if (methods.supports(METHOD.ompStatus)) {
		try {
			store.setStatus(await methods.ompStatus());
		} catch (error) {
			problems.push(`omp.status: ${describeOmpError(error)}`);
		}
	}
	if (methods.supports(METHOD.ompSessionsList)) {
		try {
			const { sessions } = await methods.ompSessionsList({
				includeEnded: true,
				limit: OMP_LIST_LIMIT,
			});
			store.applyList(sessions, sessions.length < OMP_LIST_LIMIT);
		} catch (error) {
			problems.push(`omp.sessions.list: ${describeOmpError(error)}`);
		}
	}
	return problems.length > 0 ? problems.join("; ") : undefined;
}

/** One line per session for notices: glyph, id, title, status, activity, usage. */
export function ompSessionLine(session: OmpSession): string {
	const usage = ompUsageText(session);
	return [
		`${OMP_STATUS_GLYPHS[session.status]} ${session.id}`,
		ompSessionLabel(session),
		ompStatusText(session),
		session.activity ? safeLine(session.activity, 80) : undefined,
		usage,
	]
		.filter(Boolean)
		.join(" · ");
}

async function runOmp(ctx: CommandContext, prompt: string): Promise<void> {
	let approvalMode: OmpApprovalMode | undefined;
	let isolate: boolean | undefined;
	while (prompt.startsWith("--")) {
		if (/^--isolate(?:\s|$)/.test(prompt)) {
			isolate = true;
			prompt = prompt.replace(/^--isolate\s*/, "");
		} else {
			const match = /^--approval-mode\s+(always-ask|write|yolo)(?:\s+|$)/.exec(prompt);
			if (!match) {
				ctx.ui.notice(USAGE, "warning");
				return;
			}
			approvalMode = match[1] as OmpApprovalMode;
			prompt = prompt.slice(match[0].length);
		}
	}
	if (!prompt) {
		ctx.ui.notice(USAGE, "warning");
		return;
	}
	if (!ctx.methods.supports(METHOD.ompSessionsStart)) {
		ctx.ui.notice(`daemon does not support ${METHOD.ompSessionsStart}`, "warning");
		return;
	}
	const unavailable = ompUnavailableReason(ctx.methods, ctx.store.omp);
	if (unavailable) {
		ctx.ui.notice(`/omp run: ${unavailable}`, "warning");
		return;
	}
	const cwd = ctx.cwd ?? process.cwd();
	try {
		const { session } = await ctx.methods.ompSessionsStart({
			prompt,
			cwd,
			...(approvalMode ? { approvalMode } : {}),
			...(isolate ? { isolate } : {}),
		});
		ctx.store.omp.upsert(session);
		const where = basename(cwd) || cwd;
		ctx.ui.notice(
			`omp started ${session.id} in ${safeLine(where, 60)} · ${ompStatusText(session)} — /omp or alt+m to watch`,
		);
	} catch (error) {
		ctx.ui.notice(`omp run failed: ${describeOmpError(error)}`, "error");
	}
}

async function statusOmp(ctx: CommandContext): Promise<void> {
	const problem = await syncOmp(ctx.methods, ctx.store.omp);
	const unavailable = ompUnavailableReason(ctx.methods, ctx.store.omp);
	const sessions = ctx.store.omp.sessions();
	const live = sessions.filter((session) => !isOmpSessionEnded(session));
	const busy = sessions.filter(isOmpSessionBusy).length;
	const lines = [
		`omp: ${live.length} live (${busy} running) · ${sessions.length - live.length} ended`,
	];
	if (unavailable) lines.push(unavailable);
	// A failed read is not an empty list: say the numbers may be stale.
	if (problem) lines.push(`could not refresh (${problem}); showing last known state`);
	for (const session of live) lines.push(`  ${ompSessionLine(session)}`);
	ctx.ui.noticeBlock(lines, problem ? "warning" : "info");
}

export const ompCommand: SlashCommand = {
	name: "omp",
	summary: "watch, steer and start omp delegate sessions (alt+m opens the panel)",
	usage: "[run <prompt> | status]",
	group: "runs",
	availableWhen(ctx) {
		return OMP_METHODS.some((method) => ctx.methods.supports(method))
			? true
			: "daemon does not expose the omp.* methods";
	},
	async run(ctx, argv) {
		const sub = argv[0]?.toLowerCase();
		if (!sub) {
			if (ctx.ui.openOmpPanel) ctx.ui.openOmpPanel();
			else await statusOmp(ctx);
			return;
		}
		switch (sub) {
			case "run":
				await runOmp(ctx, ctx.rest.replace(/^\S+\s*/, "").trim());
				return;
			case "status":
				await statusOmp(ctx);
				return;
			default:
				ctx.ui.notice(USAGE, "warning");
		}
	},
};
