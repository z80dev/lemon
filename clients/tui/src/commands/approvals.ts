/**
 * Approval commands.
 *
 * Pending approvals reach the client as `exec.approval.requested` events and
 * live in the {@link AppStore}; `exec.approvals.get` is the authoritative list
 * (and the policy behind it) for a client that connected mid-flight. `/approve`
 * numbers the same list `/approvals` prints, so `1` always means the first line
 * the user just read.
 *
 * Decision strings are the daemon's, not the UI's: `LemonControlPlane.Methods.
 * ExecApprovalResolve` accepts approve_once / approve_session / approve_agent /
 * approve_global / deny.
 */

import { METHOD } from "../protocol/methods.ts";
import type { ApprovalRequestedEvent } from "../protocol/types.ts";
import { asArray, humanTime, pickNumber, pickString } from "./format.ts";
import type { CommandContext, SlashCommand } from "./registry.ts";

/** Scope word the user types -> decision the daemon accepts. */
export const APPROVAL_SCOPES: Record<string, string> = {
	once: "approve_once",
	session: "approve_session",
	agent: "approve_agent",
	global: "approve_global",
	always: "approve_global",
};

export interface PendingRow {
	approvalId: string;
	tool?: string;
	sessionKey?: string;
	rationale?: string;
	requestedAtMs?: number;
}

function fromEvent(event: ApprovalRequestedEvent): PendingRow {
	return {
		approvalId: event.approvalId,
		tool: event.tool ?? undefined,
		sessionKey: event.sessionKey ?? undefined,
		rationale: event.rationale ?? undefined,
		requestedAtMs: event.requestedAtMs ?? undefined,
	};
}

/**
 * The pending list, locally-known first. A client that just connected has an
 * empty store, so an empty local list falls back to asking the daemon.
 */
export async function pendingApprovals(ctx: CommandContext): Promise<PendingRow[]> {
	const local = [...ctx.store.approvals.values()].map((entry) => fromEvent(entry.event));
	if (local.length > 0) return local;
	if (!ctx.methods.supports(METHOD.approvalsGet)) return [];
	const result = await ctx.methods.approvalsGet().catch(() => undefined);
	return asArray((result as { pending?: unknown })?.pending)
		.map((row) => ({
			approvalId: pickString(row, "approvalId", "id") ?? "",
			tool: pickString(row, "tool"),
			sessionKey: pickString(row, "sessionKey"),
			rationale: pickString(row, "rationale"),
			requestedAtMs: pickNumber(row, "requestedAtMs"),
		}))
		.filter((row) => row.approvalId.length > 0);
}

function describePending(row: PendingRow, index: number): string {
	const parts = [row.tool ?? "tool", row.sessionKey, humanTime(row.requestedAtMs), row.approvalId]
		.filter(Boolean)
		.join(" · ");
	const head = `${index + 1}. ${parts}`;
	return row.rationale ? `${head}\n   ${row.rationale}` : head;
}

export const approvalsCommand: SlashCommand = {
	name: "approvals",
	summary: "list pending approvals and the standing policy",
	group: "approvals",
	async run(ctx) {
		const pending = await pendingApprovals(ctx);
		const lines: string[] = [];
		lines.push(
			pending.length > 0 ? `pending approvals: ${pending.length}` : "no pending approvals",
		);
		for (const [index, row] of pending.entries()) lines.push(describePending(row, index));

		if (ctx.methods.supports(METHOD.approvalsGet)) {
			const result = await ctx.methods.approvalsGet().catch(() => undefined);
			const approvals = asArray((result as { approvals?: unknown })?.approvals);
			if (approvals.length > 0) {
				lines.push(`standing policy: ${approvals.length} entry(ies)`);
				for (const entry of approvals.slice(0, 20)) {
					lines.push(
						`  ${pickString(entry, "tool") ?? "?"} ${pickString(entry, "actionHash") ?? ""} → ${
							pickString(entry, "approved") ?? "?"
						} (${pickString(entry, "scope") ?? "global"})`,
					);
				}
			}
		}
		if (pending.length > 0) {
			lines.push("/approve <n> [once|session|agent|global] · /deny <n>");
		}
		ctx.ui.noticeBlock(lines);
	},
};

async function resolve(
	ctx: CommandContext,
	argv: string[],
	decision: string,
	label: string,
): Promise<void> {
	const pending = await pendingApprovals(ctx);
	if (pending.length === 0) {
		ctx.ui.notice("no pending approvals");
		return;
	}
	const index = argv[0] ? Number.parseInt(argv[0], 10) - 1 : 0;
	if (!Number.isFinite(index) || index < 0 || index >= pending.length) {
		ctx.ui.notice(`no approval #${argv[0] ?? 1} — /approvals lists ${pending.length}`, "error");
		return;
	}
	const row = pending[index];
	// The host owns the resolve when there is one: it dismisses the panel, writes
	// the store and annotates the transcript record. Only a host without an
	// approval controller (a bare command harness) falls back to the raw call.
	if (ctx.ui.resolveApproval) {
		await ctx.ui.resolveApproval(row.approvalId, decision);
		return;
	}
	await ctx.methods.approvalResolve({ approvalId: row.approvalId, decision });
	// The `exec.approval.resolved` event clears the store; this keeps the local
	// view honest when the daemon resolves without echoing (older builds).
	ctx.store.resolveApproval(row.approvalId, decision);
	ctx.ui.refreshStatus();
	ctx.ui.notice(`${label} ${row.tool ?? "tool"} (${row.approvalId})`);
}

export const approveCommand: SlashCommand = {
	name: "approve",
	summary: "approve a pending request",
	usage: "[n] [once|session|agent|global]",
	group: "approvals",
	methods: [METHOD.approvalResolve],
	async run(ctx, argv) {
		const scopeArg = argv.find((arg) => arg.toLowerCase() in APPROVAL_SCOPES);
		const decision = scopeArg ? APPROVAL_SCOPES[scopeArg.toLowerCase()] : APPROVAL_SCOPES.once;
		const positional = argv.filter((arg) => arg !== scopeArg);
		await resolve(ctx, positional, decision, `approved (${decision.replace("approve_", "")})`);
	},
};

export const denyCommand: SlashCommand = {
	name: "deny",
	summary: "deny a pending request",
	usage: "[n]",
	group: "approvals",
	methods: [METHOD.approvalResolve],
	async run(ctx, argv) {
		await resolve(ctx, argv, "deny", "denied");
	},
};
