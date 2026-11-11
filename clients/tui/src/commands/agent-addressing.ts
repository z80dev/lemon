import { randomUUID } from "node:crypto";
import { safeLine } from "../formatters/base.ts";
import {
	type AgentMessageReceipt,
	isAgentAddress,
	parseAgentReceipt,
} from "../protocol/agent-addressing.ts";
import { ControlPlaneError, describeError, MethodUnavailableError } from "../protocol/errors.ts";
import { METHOD } from "../protocol/methods.ts";
import type { AppStore } from "../store/app-store.ts";
import type { CommandContext, SlashCommand } from "./registry.ts";

interface MessageIntent {
	messageId: string;
	sourceId: string;
	targetId: string;
	text: string;
	status: AgentMessageReceipt["status"];
}

// Retain uncertain intent for explicit read-only reconciliation, never replay it.
const messages = new WeakMap<AppStore, Map<string, MessageIntent>>();
function messageLog(ctx: CommandContext): Map<string, MessageIntent> {
	let log = messages.get(ctx.store);
	if (!log) {
		log = new Map();
		messages.set(ctx.store, log);
	}
	return log;
}

function online(ctx: CommandContext): boolean {
	if (ctx.client.online) return true;
	ctx.ui.notice("offline — agent operation not sent or queued; reconnect first", "warning");
	return false;
}

async function persistSource(ctx: CommandContext): Promise<string> {
	const session = ctx.session;
	if (
		session.key.startsWith("agent:default:tui:local:dm:") &&
		!session.busy &&
		session.blocks.every((block) => block.kind === "notice")
	) {
		const created = await ctx.methods.sessionsCreate({
			sessionKey: session.key,
			cwd: ctx.cwd ?? process.cwd(),
		});
		if (
			created.sessionKey !== session.key ||
			typeof created.sessionId !== "string" ||
			!created.sessionId.trim()
		) {
			throw new Error("session creation was not verified; agent operation not sent");
		}
	}
	return `session://${session.key}`;
}

function showReceipt(ctx: CommandContext, receipt: AgentMessageReceipt): void {
	const suffix =
		receipt.status === "accepted"
			? " — queued/accepted, not an answer"
			: receipt.status === "outcome_unknown"
				? " — do not resend; check status"
				: "";
	const lines = [
		`${receipt.status}${suffix} · ${safeLine(receipt.messageId, 200)}`,
		`${safeLine(receipt.sourceId, 500)} → ${safeLine(receipt.targetId, 500)}`,
	];
	if (receipt.runId) lines.push(`run: ${safeLine(receipt.runId, 200)}`);
	if (receipt.response) lines.push(`peer response: ${safeLine(receipt.response, 32768)}`);
	if (receipt.error) lines.push(`error: ${safeLine(receipt.error, 500)}`);
	if (receipt.status === "accepted" || receipt.status === "outcome_unknown")
		lines.push(`check: /tell --status ${safeLine(receipt.messageId, 200)}`);
	ctx.ui.noticeBlock(
		lines,
		receipt.status === "failed"
			? "error"
			: receipt.status === "outcome_unknown"
				? "warning"
				: "info",
	);
}

export const agentNameCommand: SlashCommand = {
	name: "agent-name",
	summary: "set or clear this agent's address handle (not its title)",
	usage: "<handle> | --clear",
	group: "sessions",
	methods: [METHOD.agentIdentityRename],
	async run(ctx, argv) {
		if (!online(ctx)) return;
		const name = argv[0] === "--clear" ? null : argv[0]?.replace(/^@/, "").toLowerCase();
		if (argv.length !== 1 || (name !== null && (!name || !/^[a-z][a-z0-9_-]{0,63}$/.test(name)))) {
			ctx.ui.notice(
				"usage: /agent-name <handle> | --clear (1–64 ASCII letters, digits, _ or -; starts with a letter)",
				"error",
			);
			return;
		}
		const id = await persistSource(ctx);
		try {
			const { agent } = await ctx.methods.agentIdentityRename({ id, name });
			ctx.ui.notice(
				`${agent.name ? `agent @${agent.name}` : "agent handle cleared"} · ${agent.id}`,
			);
		} catch (error) {
			const details = ControlPlaneError.is(error)
				? (error.details as { retrySafe?: boolean; reason?: string } | undefined)
				: undefined;
			if (
				(ControlPlaneError.is(error) &&
					details?.retrySafe !== false &&
					details?.reason !== "outcome_unknown" &&
					!["INTERNAL_ERROR", "TIMEOUT"].includes(error.code)) ||
				error instanceof MethodUnavailableError
			)
				throw error;
			ctx.ui.notice(
				`agent rename outcome_unknown · ${id}; inspect /agents before retrying (${safeLine(describeError(error), 200)})`,
				"warning",
			);
		}
	},
};

export const agentsCommand: SlashCommand = {
	name: "agents",
	summary: "discover existing addressable agents and their stable IDs",
	usage: "[query]",
	group: "runs",
	methods: [METHOD.agentIdentityList],
	async run(ctx) {
		if (!online(ctx)) return;
		const { agents } = await ctx.methods.agentIdentityList({
			query: ctx.rest || undefined,
			limit: 100,
		});
		ctx.ui.noticeBlock([
			`current agent: session://${ctx.session.key}`,
			`agents — ${agents.length}${agents.length === 100 ? " (limit reached; narrow the query)" : ""}`,
			...agents.map(
				(agent) =>
					`${agent.name ? `@${agent.name}` : "(unnamed)"} · ${agent.id} · ${agent.status ?? "unknown"}${agent.label ? ` · ${safeLine(agent.label, 160)}` : ""}`,
			),
		]);
	},
};

export const tellCommand: SlashCommand = {
	name: "tell",
	summary: "message an existing agent or inspect a message receipt",
	usage: "<@handle|stable-id> <message> | --status <message-id>",
	group: "runs",
	availableWhen(ctx) {
		return ctx.methods.supports(METHOD.agentMessageSend) ||
			ctx.methods.supports(METHOD.agentMessageGet)
			? true
			: "daemon does not support agent.message.send or agent.message.get";
	},
	async run(ctx, argv) {
		if (!online(ctx)) return;
		const sourceId = `session://${ctx.session.key}`;
		const log = messageLog(ctx);
		if (argv[0] === "--status") {
			if (argv.length !== 2) throw new Error("usage: /tell --status <message-id>");
			const known = log.get(argv[1]);
			if (known && known.sourceId !== sourceId)
				throw new Error(
					"message belongs to a different source session; switch to that session first",
				);
			const receipt = await ctx.methods.agentMessageGet({ sourceId, messageId: argv[1] });
			parseAgentReceipt(receipt, { sourceId, messageId: argv[1], targetId: known?.targetId });
			if (known) known.status = receipt.status;
			showReceipt(ctx, receipt);
			return;
		}
		if (!ctx.methods.supports(METHOD.agentMessageSend))
			throw new MethodUnavailableError(METHOD.agentMessageSend);
		const match = ctx.rest.match(/^(\S+)\s+([\s\S]+)$/);
		if (!match?.[2].trim()) throw new Error("usage: /tell <@handle|stable-id> <message>");
		let target = match[1];
		const text = match[2];
		if (Buffer.byteLength(text, "utf8") > 32768)
			throw new Error("message exceeds 32768 UTF-8 bytes");
		if (/^@[a-z][a-z0-9_-]{0,63}$/i.test(target)) {
			const name = target.slice(1).toLowerCase();
			const { agents } = await ctx.methods.agentIdentityList({ query: name, limit: 100 });
			const matches = agents.filter((agent) => agent.name === name);
			if (matches.length !== 1)
				throw new Error(
					`agent @${name} ${matches.length ? "is ambiguous" : "was not found"}; not sent`,
				);
			target = matches[0].id;
		} else if (!isAgentAddress(target))
			throw new Error(
				"target must be @handle, session://… or bot://… (personas and task names are not addresses)",
			);
		if (target === sourceId) throw new Error("cannot message the current agent itself");
		await persistSource(ctx);
		if (!online(ctx)) return;
		// Check and reserve without yielding: source persistence can overlap another /tell.
		const pending = [...log.values()].find(
			(entry) =>
				entry.sourceId === sourceId &&
				entry.targetId === target &&
				entry.text === text &&
				(entry.status === "accepted" || entry.status === "outcome_unknown"),
		);
		if (pending) {
			ctx.ui.notice(
				`not resent: ${pending.status} · ${pending.messageId}; check /tell --status ${pending.messageId}`,
				"warning",
			);
			return;
		}
		const intent: MessageIntent = {
			sourceId,
			targetId: target,
			text,
			messageId: randomUUID(),
			status: "outcome_unknown",
		};
		log.set(intent.messageId, intent);
		try {
			const receipt = await ctx.methods.agentMessageSend({
				sourceId,
				target,
				text,
				messageId: intent.messageId,
			});
			intent.status = receipt.status;
			showReceipt(ctx, receipt);
		} catch (error) {
			// A transport loss, malformed receipt, or uncertain server mutation can
			// already have delivered. Only explicit server refusals prove failure.
			const details = ControlPlaneError.is(error)
				? (error.details as { retrySafe?: boolean; reason?: string } | undefined)
				: undefined;
			if (
				(ControlPlaneError.is(error) &&
					details?.retrySafe !== false &&
					details?.reason !== "outcome_unknown" &&
					!["INTERNAL_ERROR", "TIMEOUT"].includes(error.code)) ||
				error instanceof MethodUnavailableError
			) {
				intent.status = "failed";
				ctx.ui.notice(
					`failed · ${intent.messageId} · ${sourceId} → ${target}: ${safeLine(describeError(error), 500)}`,
					"error",
				);
			} else {
				showReceipt(ctx, { ...intent, status: "outcome_unknown" });
			}
		}
	},
};
