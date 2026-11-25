import { ControlPlaneError, classifyMutationError, failureCode } from "../protocol/errors.ts";
import { METHOD } from "../protocol/methods.ts";
import type { SessionsPlanParams, SessionsPlanResult } from "../protocol/types.ts";
import type { CommandContext, SlashCommand } from "./registry.ts";

export type PlanState = SessionsPlanResult["plan"];

const BUSY_NOTICE = "stop the current run before toggling plan mode";

/**
 * `/plan` toggles the focused session's native plan mode. While it is on the
 * agent works read-only and calls `propose_plan` when the plan is complete; the
 * proposal arrives as an ordinary approval (see the approval panel), and
 * approving it is the only way a plan is ever executed. Leaving plan mode here
 * never approves anything.
 */
export const planCommand: SlashCommand = {
	name: "plan",
	summary: "toggle plan mode (agent plans read-only, then asks to execute)",
	usage: "[request…]",
	group: "sessions",
	methods: [METHOD.sessionsPlan],
	async run(ctx) {
		const request = ctx.rest;
		if (ctx.session.busy) {
			ctx.ui.notice(BUSY_NOTICE, "warning");
			return;
		}
		if (request && !ctx.ui.deliverPrompt) {
			ctx.ui.notice(
				"this build cannot send a planning request; use /plan, then send the request as a prompt",
				"warning",
			);
			return;
		}
		const target: Target = { sessionKey: ctx.session.key, cwd: ctx.cwd ?? process.cwd() };
		let current: PlanState;
		try {
			current = await call(ctx, target, "status");
		} catch (error) {
			failure(ctx, error);
			return;
		}
		if (ctx.store.focusedKey !== target.sessionKey) return;

		if (request) {
			if (current.mode !== "plan" && !(await enter(ctx, target))) return;
			await ctx.ui.deliverPrompt!(request, "queue");
			return;
		}
		if (current.mode === "code") {
			await enter(ctx, target);
			return;
		}
		if (!current.content?.trim()) {
			await exit(ctx, target);
			return;
		}
		let settled = false;
		ctx.ui.openPicker({
			title: "Exit plan mode?",
			detail: [
				"This exits plan mode without approving a plan.",
				...(current.path ? [`Plan file: ${current.path}`] : []),
			],
			items: [
				{ value: "cancel", label: "Cancel — stay in plan mode" },
				{ value: "exit", label: "Exit plan mode without approving" },
			],
			footer: "cancel is selected by default · the agent asks before executing any plan",
			onCancel: () => {
				settled = true;
			},
			onSelect: async (choice) => {
				if (settled) return;
				settled = true;
				if (choice.value !== "exit") return;
				if (ctx.store.focusedKey !== target.sessionKey || ctx.store.focused.busy) {
					ctx.ui.notice(
						"plan mode exit canceled because the focused session or run changed",
						"warning",
					);
					return;
				}
				await exit(ctx, target);
			},
		});
	},
};

interface Target {
	sessionKey: string;
	cwd: string;
}

/** Turn plan mode on. Resolves false (after saying why) when the daemon did not. */
async function enter(ctx: CommandContext, target: Target): Promise<boolean> {
	try {
		const plan = await call(ctx, target, "enter");
		if (plan.mode !== "plan") throw new Error("plan mode was not entered");
		if (ctx.store.focusedKey === target.sessionKey) {
			ctx.ui.notice(
				`plan mode on — read-only; the agent will propose a plan for approval${plan.path ? ` (plan file: ${plan.path})` : ""}`,
			);
		}
		return true;
	} catch (error) {
		failure(ctx, error);
		return false;
	}
}

async function exit(ctx: CommandContext, target: Target): Promise<void> {
	try {
		const plan = await call(ctx, target, "exit");
		if (plan.mode !== "code") throw new Error("plan mode was not exited");
		if (ctx.store.focusedKey === target.sessionKey) {
			ctx.ui.notice("plan mode off; nothing was approved or executed");
		}
	} catch (error) {
		failure(ctx, error);
	}
}

/** One validated round-trip; the receipt is recorded on the session it names. */
async function call(
	ctx: CommandContext,
	target: Target,
	action: SessionsPlanParams["action"],
): Promise<PlanState> {
	const result = await ctx.methods.sessionsPlan({ ...target, action });
	const plan = parsePlanReceipt(result, target.sessionKey);
	ctx.store.session(target.sessionKey).setPlan(plan.mode, plan.path);
	ctx.ui.refreshStatus();
	return plan;
}

/** The receipt's plan, or a throw when it is not a well-formed answer for `sessionKey`. */
export function parsePlanReceipt(result: SessionsPlanResult, sessionKey: string): PlanState {
	const plan = result?.plan;
	if (
		result?.sessionKey !== sessionKey ||
		!plan ||
		(plan.mode !== "code" && plan.mode !== "plan") ||
		![plan.path, plan.content].every((value) => value === null || typeof value === "string")
	)
		throw new Error("invalid plan receipt");
	return plan;
}

function failure(ctx: CommandContext, error: unknown): void {
	// The daemon refuses enter/exit during a run with CONFLICT `{reason: "busy"}`.
	const details = ControlPlaneError.is(error, "CONFLICT") ? error.details : undefined;
	if (
		typeof details === "object" &&
		details !== null &&
		"reason" in details &&
		details.reason === "busy"
	) {
		ctx.ui.notice(BUSY_NOTICE, "warning");
		return;
	}
	const code = failureCode(error, "OUTCOME_UNKNOWN");
	ctx.ui.notice(
		classifyMutationError(error) === "unknown"
			? `plan mode change outcome unknown (${code}); run /plan to check the current mode before retrying. No prompt was sent.`
			: `plan mode change did not complete (${code}); run /plan to check the current mode. No prompt was sent.`,
		"error",
	);
}
