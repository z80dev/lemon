/**
 * Session commands: listing, switching, lifecycle and history replay.
 *
 * `/sessions` reuses the full switcher when mounted and falls back to the same
 * merged rows in a generic picker. Search arguments query the durable server
 * roster first, then the accessible picker provides live local refinement.
 */

import { createHash, randomUUID } from "node:crypto";
import {
	chmodSync,
	closeSync,
	constants as fsConstants,
	fsyncSync,
	lstatSync,
	mkdirSync,
	openSync,
	renameSync,
	unlinkSync,
	writeFileSync,
} from "node:fs";
import { basename, dirname, resolve } from "node:path";
import { ControlPlaneError, NotConnectedError } from "../protocol/errors.ts";
import type { ControlPlaneMethods } from "../protocol/methods.ts";
import { METHOD } from "../protocol/methods.ts";
import type {
	ChatHistoryMessage,
	SessionExportFormat,
	SessionPreviewEntry,
	SessionSummary,
	SessionsExportResult,
	SessionsListParams,
	SessionsPruneParams,
} from "../protocol/types.ts";
import type { AppStore } from "../store/app-store.ts";
import { asArray, asRecord, humanTime, pickNumber, pickString } from "./format.ts";
import type { CommandContext, PickerChoice, SlashCommand } from "./registry.ts";

const HISTORY_DEFAULT = 20;

const MAX_SEARCH_QUERY_BYTES = 512;
const MAX_TITLE_LENGTH = 160;
const MAX_PRUNE_ROWS_SHOWN = 30;
const MAX_EXPORT_BYTES = 750_000;

/** How many stored sessions the merged list asks for. */
export const SESSION_LIST_LIMIT = 100;

/**
 * Exact-key lifecycle operations search the server's full bounded page before
 * mutating or switching. This is deliberately the server maximum rather than
 * the shorter browse page: an exact key must never disappear behind a busy
 * recent-session roster.
 */
const EXACT_SESSION_LOOKUP_LIMIT = 500;

export interface SessionRow {
	key: string;
	agentId?: string;
	/** Running server-side, or busy in this client. */
	active: boolean;
	updatedAtMs?: number;
	runCount?: number;
	/** This client has a transcript for it. */
	local: boolean;
	/** Blocks that arrived while it was off screen. */
	unread: number;
	model?: string;
	title?: string;
	pinned: boolean;
	archived: boolean;
	origin?: string;
}

/** What the merge needs; {@link CommandContext} satisfies it structurally. */
export interface SessionSource {
	store: AppStore;
	methods: ControlPlaneMethods;
}

/**
 * Merge `sessions.active.list`, `sessions.list` and locally-known sessions into
 * one list, newest first with live sessions on top. Both remote calls are
 * best-effort: a daemon that cannot answer one still produces a usable list from
 * the others, which is what keeps the switcher openable while reconnecting.
 */
export async function collectSessions(source: SessionSource): Promise<SessionRow[]> {
	const rows = new Map<string, SessionRow>();
	const add = (summary: SessionSummary, active: boolean) => {
		const key = pickString(summary, "sessionKey", "session_key", "key");
		if (!key) return;
		const existing = rows.get(key);
		rows.set(key, {
			key,
			agentId: pickString(summary, "agentId") ?? existing?.agentId,
			active: active || (existing?.active ?? false),
			updatedAtMs: pickNumber(summary, "updatedAtMs") ?? existing?.updatedAtMs,
			runCount: pickNumber(summary, "runCount") ?? existing?.runCount,
			local: existing?.local ?? false,
			unread: existing?.unread ?? 0,
			model: pickString(summary, "model") ?? existing?.model,
			title: pickString(summary, "title") ?? existing?.title,
			pinned: summary.pinned === true || (existing?.pinned ?? false),
			archived: summary.archived === true || (existing?.archived ?? false),
			origin: pickString(summary, "origin") ?? existing?.origin,
		});
	};

	if (source.methods.supports(METHOD.sessionsActiveList)) {
		const result = await source.methods.sessionsActiveList().catch(() => undefined);
		for (const entry of asArray(result?.sessions)) add(entry as SessionSummary, true);
	}
	if (source.methods.supports(METHOD.sessionsList)) {
		const result = await source.methods
			.sessionsList({ limit: SESSION_LIST_LIMIT })
			.catch(() => undefined);
		for (const entry of asArray(result?.sessions)) add(entry as SessionSummary, false);
	}
	for (const session of source.store.sessions.values()) {
		const existing = rows.get(session.key);
		rows.set(session.key, {
			key: session.key,
			agentId: existing?.agentId,
			active: session.busy || (existing?.active ?? false),
			// A locally-known session's last block is a better "when" than a
			// remote timestamp the daemon may only refresh on completion.
			updatedAtMs: Math.max(existing?.updatedAtMs ?? 0, session.lastBlock?.at ?? 0) || undefined,
			runCount: existing?.runCount,
			local: true,
			unread: session.unread,
			model: session.model ?? existing?.model,
			title: existing?.title,
			pinned: existing?.pinned ?? false,
			archived: existing?.archived ?? false,
			origin: existing?.origin,
		});
	}
	return [...rows.values()].sort((left, right) => {
		if (left.active !== right.active) return left.active ? -1 : 1;
		return (right.updatedAtMs ?? 0) - (left.updatedAtMs ?? 0);
	});
}

function describeRow(row: SessionRow, focusedKey: string): PickerChoice {
	const marks = [
		row.key === focusedKey ? "current" : undefined,
		row.active ? "active" : undefined,
		row.local ? "local" : undefined,
		row.unread > 0 ? `${row.unread} unread` : undefined,
		row.runCount !== undefined ? `${row.runCount} run(s)` : undefined,
		row.pinned ? "pinned" : undefined,
		row.archived ? "archived" : undefined,
		humanTime(row.updatedAtMs),
	].filter(Boolean);
	return {
		value: row.key,
		label: row.title ? `${oneLine(row.title, 60)} (${row.key})` : row.key,
		description: marks.join(" · "),
	};
}

export const sessionsCommand: SlashCommand = {
	name: "sessions",
	summary: "browse or safely search durable sessions (also Ctrl+X)",
	usage: "[query…] [--pinned|--unpinned] [--archived|--active] [--agent <id>] [--limit <n>]",
	group: "sessions",
	async run(ctx, argv) {
		try {
			if (argv.length > 0) {
				await searchSessions(ctx, argv);
				return;
			}
			// The switcher shows the same merged list with the lifecycle keys bound,
			// so it wins whenever the UI has one mounted.
			if (ctx.ui.openSessionSwitcher) {
				ctx.ui.openSessionSwitcher();
				return;
			}
			const rows = await collectSessions(ctx);
			if (rows.length === 0) {
				ctx.ui.notice("no sessions");
				return;
			}
			const items = rows.map((row) => describeRow(row, ctx.store.focusedKey));
			ctx.ui.openPicker({
				title: "sessions",
				items,
				footer: "enter switches · esc cancels",
				onSelect: async (choice) => {
					await switchTo(ctx, choice.value);
				},
			});
		} catch (error) {
			safeSessionFailure(ctx, "search", error);
		}
	},
};

async function switchTo(ctx: CommandContext, key: string): Promise<void> {
	if (key === ctx.store.focusedKey) {
		ctx.ui.notice(`already on ${key}`);
		return;
	}
	if (!ctx.ui.switchSession) {
		// P6 owns the switch (draft persistence, cold hydration, scrollback).
		ctx.ui.notice(`session switching arrives with the switcher; ${key} is not focused`, "warning");
		return;
	}
	await ctx.ui.switchSession(key);
}

export const sessionCommand: SlashCommand = {
	name: "session",
	summary: "inspect, resume, annotate, export, or safely remove sessions",
	usage:
		"[help|current|show|search|open|resume|title|pin|unpin|archive|unarchive|preview|export|prune|delete|new|reset] …",
	group: "sessions",
	async run(ctx, argv) {
		const action = (argv[0] ?? "current").toLowerCase();
		try {
			switch (action) {
				case "help":
					renderSessionHelp(ctx);
					return;
				case "current":
				case "info": {
					await showSession(ctx, ctx.session.key, true);
					return;
				}
				case "show": {
					await showSession(ctx, argv[1] ?? ctx.session.key, false);
					return;
				}
				case "search": {
					await searchSessions(ctx, argv.slice(1));
					return;
				}
				case "open":
				case "select": {
					await openSession(ctx, argv[1]);
					return;
				}
				case "resume": {
					await resumeSession(ctx, argv.slice(1));
					return;
				}
				case "title": {
					await titleSession(ctx, argv.slice(1));
					return;
				}
				case "pin":
				case "unpin":
				case "archive":
				case "unarchive":
				case "restore": {
					await patchSessionFlag(ctx, action, argv[1] ?? ctx.session.key);
					return;
				}
				case "preview": {
					await previewSession(ctx, argv.slice(1));
					return;
				}
				case "export": {
					await exportSession(ctx, argv.slice(1));
					return;
				}
				case "prune": {
					await pruneSessions(ctx, argv.slice(1));
					return;
				}
				case "new": {
					// `/session new [key] [first prompt…]` — everything past the key is
					// the first message, which is also what mints the session daemon-side.
					const key = argv[1];
					const prompt = argv.slice(2).join(" ").trim();
					if (!ctx.ui.createSession) {
						ctx.ui.notice("this build cannot create sessions", "warning");
						return;
					}
					await ctx.ui.createSession(key, prompt.length > 0 ? prompt : undefined);
					ctx.ui.notice(`new session ${ctx.store.focusedKey}`);
					return;
				}
				case "switch": {
					const key = argv[1];
					if (!key) {
						ctx.ui.notice("usage: /session switch <key>", "error");
						return;
					}
					await switchTo(ctx, key);
					return;
				}
				case "reset": {
					if (!ctx.methods.supports(METHOD.sessionsReset)) {
						ctx.ui.notice(`daemon does not support ${METHOD.sessionsReset}`, "warning");
						return;
					}
					await ctx.methods.sessionsReset({ sessionKey: ctx.session.key });
					// Both sides forget together: a cleared server history under a
					// transcript still on screen is a session the user cannot reason
					// about, and the next switch would rebuild the stale half.
					ctx.ui.resetSession?.(ctx.session.key);
					ctx.ui.notice(`reset ${ctx.session.key} (history cleared here and on the daemon)`);
					return;
				}
				case "delete":
				case "close": {
					await deleteSession(ctx, argv.slice(1));
					return;
				}
				default:
					ctx.ui.notice(`usage: /session ${sessionCommand.usage}`, "error");
			}
		} catch (error) {
			safeSessionFailure(ctx, action, error);
		}
	},
};

function renderSessionHelp(ctx: CommandContext): void {
	ctx.ui.noticeBlock([
		"session commands",
		"/sessions [query…] [--pinned|--unpinned] [--archived|--active] [--agent <id>] [--limit <n>]",
		"/session current | show [key] | search <query…> | open <key> | resume [key] [count]",
		"/session title <key> <title…> | title <key> --clear",
		"/session pin|unpin|archive|unarchive [key]",
		"/session preview [key] [count]",
		"/session export [key] [json|markdown] [--output <path>] [--force]",
		"/session prune --older-than <30d|ISO-date|unix-ms> [--all] [--include-pinned] [--confirm <token>]",
		"/session delete [key] --confirm <exact-key> [--export json|markdown] [--output <path>]",
		"destructive operations are never queued while offline; previews and exact confirmations are required",
	]);
}

interface ParsedSearch {
	params: SessionsListParams;
	query?: string;
}

async function searchSessions(ctx: CommandContext, argv: string[]): Promise<void> {
	if (!requireSessionMethod(ctx, METHOD.sessionsList)) return;
	const parsed = parseSearchArgs(argv);
	if (typeof parsed === "string") {
		ctx.ui.notice(`${parsed} · usage: /sessions ${sessionsCommand.usage}`, "error");
		return;
	}
	const result = await ctx.methods.sessionsList(parsed.params);
	const rows = sessionRowsFrom(result).flatMap((summary) => {
		const row = rowFromSummary(summary, ctx.store);
		return row ? [row] : [];
	});
	if (rows.length === 0) {
		ctx.ui.notice("no matching durable sessions");
		return;
	}
	ctx.ui.openPicker({
		title: parsed.query ? "session search" : "filtered sessions",
		items: rows.map((row) => describeRow(row, ctx.store.focusedKey)),
		footer: "type to refine · enter opens · esc cancels",
		onSelect: (choice) => switchTo(ctx, choice.value),
	});
}

function parseSearchArgs(argv: string[]): ParsedSearch | string {
	const params: SessionsListParams = { limit: SESSION_LIST_LIMIT };
	const queryParts: string[] = [];
	let pinned: boolean | undefined;
	let archived: boolean | undefined;
	for (let index = 0; index < argv.length; index += 1) {
		const arg = argv[index]!;
		switch (arg) {
			case "--pinned":
				if (pinned === false) return "do not combine --pinned and --unpinned";
				pinned = true;
				break;
			case "--unpinned":
				if (pinned === true) return "do not combine --pinned and --unpinned";
				pinned = false;
				break;
			case "--archived":
				if (archived === false) return "do not combine --archived and --active";
				archived = true;
				break;
			case "--active":
				if (archived === true) return "do not combine --archived and --active";
				archived = false;
				break;
			case "--agent": {
				const value = argv[++index];
				if (!value || value.startsWith("--")) return "--agent requires an id";
				params.agentId = value;
				break;
			}
			case "--limit": {
				const value = Number.parseInt(argv[++index] ?? "", 10);
				if (!Number.isInteger(value) || value < 1 || value > 500)
					return "--limit must be between 1 and 500";
				params.limit = value;
				break;
			}
			default:
				if (arg.startsWith("--")) return `unknown session filter "${arg}"`;
				queryParts.push(arg);
		}
	}
	const query = queryParts.join(" ").trim();
	if (Buffer.byteLength(query, "utf8") > MAX_SEARCH_QUERY_BYTES)
		return `search query must be at most ${MAX_SEARCH_QUERY_BYTES} bytes`;
	if (query) params.query = query;
	if (pinned !== undefined) params.pinned = pinned;
	if (archived !== undefined) params.archived = archived;
	return { params, query: query || undefined };
}

function rowFromSummary(summary: SessionSummary, store: AppStore): SessionRow | undefined {
	const key = pickString(summary, "sessionKey", "session_key", "key");
	if (!key) return undefined;
	const local = store.sessions.get(key);
	return {
		key,
		agentId: pickString(summary, "agentId"),
		active: local?.busy ?? false,
		updatedAtMs: pickNumber(summary, "updatedAtMs"),
		runCount: pickNumber(summary, "runCount"),
		local: local !== undefined,
		unread: local?.unread ?? 0,
		model: pickString(summary, "model") ?? local?.model,
		title: pickString(summary, "title"),
		pinned: summary.pinned === true,
		archived: summary.archived === true,
		origin: pickString(summary, "origin"),
	};
}

async function loadExactSession(
	ctx: CommandContext,
	key: string,
): Promise<SessionSummary | undefined> {
	if (!requireSessionMethod(ctx, METHOD.sessionsList)) return undefined;
	const result = await ctx.methods.sessionsList({
		query: key,
		limit: EXACT_SESSION_LOOKUP_LIMIT,
	});
	return sessionRowsFrom(result).find((entry) => pickString(entry, "sessionKey") === key);
}

async function showSession(ctx: CommandContext, key: string, current: boolean): Promise<void> {
	let row: SessionSummary | undefined;
	let metadataUnavailable = false;
	try {
		row = await loadExactSession(ctx, key);
	} catch (error) {
		if (!current) throw error;
		// Current-session inspection must remain useful during rolling upgrades
		// and transient lifecycle failures. The fallback contains only fields
		// already resident in the TUI store, never daemon error details.
		metadataUnavailable = true;
	}
	if (!row) {
		if (current && key === ctx.session.key) {
			ctx.ui.noticeBlock([
				`session ${key} · current · ${metadataUnavailable ? "durable metadata unavailable" : "not yet durable"}`,
				`blocks: ${ctx.session.blocks.length} · unread: ${ctx.session.unread}`,
				`busy: ${ctx.session.busy}${ctx.session.activeRunId ? " · active run present" : ""}`,
				`model: ${ctx.session.model ?? "daemon default"} · native runtime: ${ctx.session.engine ?? "not reported"}`,
				`thinking: ${ctx.session.thinkingLevel ?? "daemon default"} · tool policy: ${ctx.session.toolPolicy ?? "daemon default"}`,
			]);
			return;
		}
		ctx.ui.notice("session was not found; refresh the session picker", "warning");
		return;
	}
	const title = pickString(row, "title");
	ctx.ui.noticeBlock([
		`session ${key}${current ? " · current" : ""}`,
		`title: ${title ? oneLine(title, 120) : "(none)"}`,
		`agent: ${pickString(row, "agentId") ?? "unknown"} · origin: ${pickString(row, "origin") ?? "unknown"}`,
		`runs: ${pickNumber(row, "runCount") ?? 0} · pinned: ${row.pinned === true} · archived: ${row.archived === true}`,
		`updated: ${humanTime(pickNumber(row, "updatedAtMs")) ?? "unknown"} · model override: ${pickString(row, "model") ?? "inherited"}`,
		...(current
			? [
					`native runtime: ${ctx.session.engine ?? "not reported"} · thinking: ${ctx.session.thinkingLevel ?? "daemon default"}`,
				]
			: []),
	]);
}

async function openSession(ctx: CommandContext, key: string | undefined): Promise<void> {
	if (!key) {
		ctx.ui.notice("usage: /session open <key>", "error");
		return;
	}
	if (!(await loadExactSession(ctx, key))) {
		ctx.ui.notice("session was not found; no draft or focus changed", "warning");
		return;
	}
	await switchTo(ctx, key);
}

async function resumeSession(ctx: CommandContext, argv: string[]): Promise<void> {
	if (!requireSessionMethod(ctx, METHOD.chatHistory)) return;
	const key = argv[0] && !/^\d+$/.test(argv[0]) ? argv[0] : ctx.session.key;
	const countArg = argv.find((arg) => /^\d+$/.test(arg));
	const limit = countArg ? Math.min(Number.parseInt(countArg, 10), 200) : 50;
	if (!(await loadExactSession(ctx, key))) {
		ctx.ui.notice("session was not found; no transcript changed", "warning");
		return;
	}
	if (key !== ctx.session.key) {
		await switchTo(ctx, key);
		return;
	}
	const result = await ctx.methods.chatHistory({
		sessionKey: key,
		limit,
		includeFullText: true,
	});
	const messages = (result.messages ?? []) as ChatHistoryMessage[];
	if (messages.length === 0) {
		ctx.ui.notice(`no stored history for ${key}`);
		return;
	}
	ctx.ui.replayHistory(messages);
	ctx.ui.notice(`resumed ${messages.length} stored message(s) in ${key}`);
}

async function titleSession(ctx: CommandContext, argv: string[]): Promise<void> {
	if (!requireSessionMethod(ctx, METHOD.sessionsMetadataPatch)) return;
	const key = argv[0] === "current" ? ctx.session.key : argv[0];
	if (!key) {
		ctx.ui.notice("usage: /session title <key> <title…> | /session title <key> --clear", "error");
		return;
	}
	const tail = argv.slice(1);
	const clear = tail.length === 1 && tail[0] === "--clear";
	const title = tail.join(" ").trim();
	if (!clear && (!title || title.length > MAX_TITLE_LENGTH)) {
		ctx.ui.notice(`title must contain 1-${MAX_TITLE_LENGTH} characters, or use --clear`, "error");
		return;
	}
	if (!clear && tail.includes("--clear")) {
		ctx.ui.notice("do not combine title text with --clear", "error");
		return;
	}
	const result = await ctx.methods.sessionsMetadataPatch({
		sessionKey: key,
		title: clear ? null : title,
	});
	ctx.ui.notice(
		`title ${clear ? "cleared" : "updated"} for ${key} (${result.metadata.titleBytes} bytes)`,
	);
}

async function patchSessionFlag(ctx: CommandContext, action: string, key: string): Promise<void> {
	if (!requireSessionMethod(ctx, METHOD.sessionsMetadataPatch)) return;
	const field = action === "pin" || action === "unpin" ? "pinned" : "archived";
	const value = action === "pin" || action === "archive";
	const result = await ctx.methods.sessionsMetadataPatch({ sessionKey: key, [field]: value });
	if (!result.success) throw new Error("metadata patch was not verified");
	const label =
		action === "restore" || action === "unarchive"
			? "unarchived"
			: action === "unpin"
				? "unpinned"
				: action === "pin"
					? "pinned"
					: "archived";
	ctx.ui.notice(`${label} ${key}`);
}

async function previewSession(ctx: CommandContext, argv: string[]): Promise<void> {
	if (!requireSessionMethod(ctx, METHOD.sessionsPreview)) return;
	const key = argv[0] && !/^\d+$/.test(argv[0]) ? argv[0] : ctx.session.key;
	const countArg = argv.find((arg) => /^\d+$/.test(arg));
	const limit = countArg ? Math.min(Number.parseInt(countArg, 10), 100) : 10;
	const result = await ctx.methods.sessionsPreview({ sessionKey: key, limit });
	if (result.preview.length === 0) {
		ctx.ui.notice(`no redacted preview available for ${key}`);
		return;
	}
	ctx.ui.noticeBlock([
		`redacted preview of ${key} · ${result.preview.length} run(s)`,
		...result.preview.flatMap((entry) => previewLines(entry)),
	]);
}

function previewLines(entry: SessionPreviewEntry): string[] {
	const when = humanTime(entry.timestampMs ?? undefined);
	const status = entry.ok === true ? "ok" : entry.ok === false ? "error" : "unknown";
	return [
		`${entry.runId ?? "run"} · ${status}${when ? ` · ${when}` : ""}`,
		`  user: ${oneLine(entry.prompt ?? "", 120)}`,
		`  assistant: ${oneLine(entry.answer ?? "", 160)}`,
	];
}

interface ExportOptions {
	key: string;
	format: SessionExportFormat;
	output?: string;
	force: boolean;
}

async function exportSession(ctx: CommandContext, argv: string[]): Promise<void> {
	if (!requireSessionMethod(ctx, METHOD.sessionsExport)) return;
	const parsed = parseExportArgs(argv, ctx.session.key);
	if (typeof parsed === "string") {
		ctx.ui.notice(
			`${parsed} · usage: /session export [key] [json|markdown] [--output <path>] [--force]`,
			"error",
		);
		return;
	}
	await exportAndWrite(ctx, parsed);
}

function parseExportArgs(argv: string[], defaultKey: string): ExportOptions | string {
	let key = defaultKey;
	let format: SessionExportFormat = "json";
	let output: string | undefined;
	let force = false;
	let keySeen = false;
	for (let index = 0; index < argv.length; index += 1) {
		const arg = argv[index]!;
		if (arg === "--force") {
			force = true;
		} else if (arg === "--output") {
			const value = argv[++index];
			if (!value || value.startsWith("--")) return "--output requires a file path";
			output = value;
		} else if (arg === "--format") {
			const value = normalizeExportFormat(argv[++index]);
			if (!value) return "--format must be json or markdown";
			format = value;
		} else if (arg === "json" || arg === "markdown" || arg === "md") {
			const value = normalizeExportFormat(arg);
			if (value) format = value;
		} else if (arg.startsWith("--")) {
			return `unknown export option "${arg}"`;
		} else if (!keySeen) {
			key = arg === "current" ? defaultKey : arg;
			keySeen = true;
		} else {
			return "export accepts at most one session key and one format";
		}
	}
	return { key, format, output, force };
}

function normalizeExportFormat(value: string | undefined): SessionExportFormat | undefined {
	if (value === "json") return "json";
	if (value === "markdown" || value === "md") return "markdown";
	return undefined;
}

async function exportAndWrite(
	ctx: CommandContext,
	options: ExportOptions,
): Promise<SessionsExportResult> {
	const result = await ctx.methods.sessionsExport({
		sessionKey: options.key,
		format: options.format,
	});
	verifyExport(result, options.key, options.format);
	const destination = resolve(ctx.cwd ?? process.cwd(), options.output ?? result.filename);
	writePrivateExport(destination, result.content, options.force);
	ctx.ui.notice(
		`redacted ${result.format} export written to ${basename(destination)} · ${result.bytes} bytes · sha256 ${result.sha256}`,
	);
	return result;
}

function verifyExport(
	result: SessionsExportResult,
	key: string,
	format: SessionExportFormat,
): void {
	const digest = createHash("sha256").update(result.content, "utf8").digest("hex");
	if (
		result.sessionKey !== key ||
		result.format !== format ||
		result.redacted !== true ||
		result.bytes > MAX_EXPORT_BYTES ||
		Buffer.byteLength(result.content, "utf8") !== result.bytes ||
		result.sha256 !== digest
	) {
		throw new Error("redacted export integrity check failed");
	}
}

function writePrivateExport(path: string, content: string, force: boolean): void {
	mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
	try {
		const stat = lstatSync(path);
		if (!stat.isFile()) throw new Error("unsafe export destination");
		if (!force) throw new Error("export destination already exists; pass --force to replace it");
	} catch (error) {
		const code = (error as NodeJS.ErrnoException).code;
		if (code !== "ENOENT") throw error;
	}
	const temporary = `${path}.lemon-${randomUUID()}.tmp`;
	let descriptor: number | undefined;
	try {
		descriptor = openSync(
			temporary,
			fsConstants.O_WRONLY |
				fsConstants.O_CREAT |
				fsConstants.O_EXCL |
				(fsConstants.O_NOFOLLOW ?? 0),
			0o600,
		);
		writeFileSync(descriptor, content, { encoding: "utf8" });
		fsyncSync(descriptor);
		closeSync(descriptor);
		descriptor = undefined;
		chmodSync(temporary, 0o600);
		renameSync(temporary, path);
	} catch (error) {
		if (descriptor !== undefined) closeSync(descriptor);
		try {
			unlinkSync(temporary);
		} catch {
			// The temporary file may not have been created.
		}
		throw error;
	}
}

async function pruneSessions(ctx: CommandContext, argv: string[]): Promise<void> {
	if (!requireSessionMethod(ctx, METHOD.sessionsPrune)) return;
	const parsed = parsePruneArgs(argv);
	if (typeof parsed === "string") {
		ctx.ui.notice(
			`${parsed} · usage: /session prune --older-than <30d|ISO-date|unix-ms> [--all] [--include-pinned] [--confirm <token>]`,
			"error",
		);
		return;
	}
	const result = await ctx.methods.sessionsPrune(parsed);
	if (parsed.dryRun !== false) {
		const candidates = result.candidateSessionKeys.slice(0, MAX_PRUNE_ROWS_SHOWN);
		ctx.ui.noticeBlock([
			`prune preview · ${result.candidateCount} exact candidate(s) · archived only: ${result.archivedOnly} · pinned included: ${result.includePinned}`,
			...candidates.map((key) => `  ${key}`),
			...(result.candidateCount > candidates.length
				? [`  … ${result.candidateCount - candidates.length} more candidate(s)`]
				: []),
			...(result.candidateCount > 0
				? [
						`confirm only this exact set: /session prune --older-than ${result.olderThanMs} ${result.archivedOnly ? "" : "--all "}${result.includePinned ? "--include-pinned " : ""}--confirm ${result.confirmToken}`,
					]
				: ["nothing will be deleted"]),
		]);
		return;
	}
	if (!result.verified || result.deletedCount !== result.deletedSessionKeys.length) {
		throw new Error("prune deletion was not verified");
	}
	for (const key of result.deletedSessionKeys) await ctx.ui.forgetDeletedSession?.(key);
	ctx.ui.notice(
		`verified prune deleted ${result.deletedCount} session(s) from the exact preview set`,
		"warning",
	);
}

function parsePruneArgs(argv: string[]): SessionsPruneParams | string {
	let cutoff: number | undefined;
	let archivedOnly = true;
	let includePinned = false;
	let confirmToken: string | undefined;
	for (let index = 0; index < argv.length; index += 1) {
		const arg = argv[index]!;
		if (arg === "--older-than") {
			const value = argv[++index];
			if (!value) return "--older-than requires a cutoff";
			cutoff = parseCutoff(value);
			if (!cutoff)
				return "--older-than must be a duration, ISO date, or positive unix milliseconds";
		} else if (arg === "--all") {
			archivedOnly = false;
		} else if (arg === "--include-pinned") {
			includePinned = true;
		} else if (arg === "--confirm") {
			confirmToken = argv[++index];
			if (!confirmToken || confirmToken.startsWith("--"))
				return "--confirm requires the preview token";
		} else {
			return `unknown prune option "${arg}"`;
		}
	}
	if (!cutoff) return "--older-than is required";
	return {
		olderThanMs: cutoff,
		archivedOnly,
		includePinned,
		dryRun: confirmToken === undefined,
		...(confirmToken ? { confirmToken } : {}),
	};
}

function parseCutoff(value: string, now = Date.now()): number | undefined {
	if (/^\d+$/.test(value)) {
		const parsed = Number.parseInt(value, 10);
		return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : undefined;
	}
	const duration = value.match(/^(\d+)([mhdw])$/i);
	if (duration) {
		const amount = Number.parseInt(duration[1]!, 10);
		const unitMs = { m: 60_000, h: 3_600_000, d: 86_400_000, w: 604_800_000 }[
			duration[2]!.toLowerCase()
		] as number;
		const cutoff = now - amount * unitMs;
		return cutoff > 0 ? cutoff : undefined;
	}
	const parsed = Date.parse(value);
	return Number.isFinite(parsed) && parsed > 0 ? parsed : undefined;
}

interface DeleteOptions {
	key: string;
	confirm?: string;
	exportFormat?: SessionExportFormat;
	output?: string;
	force: boolean;
}

async function deleteSession(ctx: CommandContext, argv: string[]): Promise<void> {
	if (!requireSessionMethod(ctx, METHOD.sessionsDelete)) return;
	const parsed = parseDeleteArgs(argv, ctx.session.key);
	if (typeof parsed === "string") {
		ctx.ui.notice(
			`${parsed} · usage: /session delete [key] --confirm <exact-key> [--export json|markdown] [--output <path>]`,
			"error",
		);
		return;
	}
	const candidate = await loadExactSession(ctx, parsed.key);
	if (!candidate) {
		ctx.ui.notice("session was not found; nothing was deleted", "warning");
		return;
	}
	if (parsed.confirm !== parsed.key) {
		ctx.ui.noticeBlock(
			[
				`delete preview · ${parsed.key}`,
				`title present: ${Boolean(pickString(candidate, "title"))} · runs: ${pickNumber(candidate, "runCount") ?? 0} · pinned: ${candidate.pinned === true} · archived: ${candidate.archived === true}`,
				`confirm this exact session: /session delete ${parsed.key} --confirm ${parsed.key}`,
				`add --export json|markdown [--output <path>] to save and verify a redacted export before deletion`,
			],
			"warning",
		);
		return;
	}
	let exported: SessionsExportResult | undefined;
	if (parsed.exportFormat || parsed.output) {
		if (!requireSessionMethod(ctx, METHOD.sessionsExport)) return;
		exported = await exportAndWrite(ctx, {
			key: parsed.key,
			format: parsed.exportFormat ?? "json",
			output: parsed.output,
			force: parsed.force,
		});
	}
	const result = await ctx.methods.sessionsDelete({ sessionKey: parsed.key });
	if (!result.deleted || result.summary?.verified !== true) {
		throw new Error("session deletion was not verified");
	}
	await ctx.ui.forgetDeletedSession?.(parsed.key);
	ctx.ui.notice(
		`verified deletion of ${parsed.key}${exported ? ` after redacted ${exported.format} export ${exported.sha256}` : ""}`,
		"warning",
	);
}

function parseDeleteArgs(argv: string[], defaultKey: string): DeleteOptions | string {
	let key = defaultKey;
	let keySeen = false;
	let confirm: string | undefined;
	let exportFormat: SessionExportFormat | undefined;
	let output: string | undefined;
	let force = false;
	for (let index = 0; index < argv.length; index += 1) {
		const arg = argv[index]!;
		if (arg === "--confirm") {
			confirm = argv[++index];
			if (!confirm || confirm.startsWith("--")) return "--confirm requires the exact session key";
		} else if (arg === "--export") {
			const next = argv[index + 1];
			const normalized = normalizeExportFormat(next);
			exportFormat = normalized ?? "json";
			if (normalized) index += 1;
		} else if (arg === "--output") {
			output = argv[++index];
			if (!output || output.startsWith("--")) return "--output requires a file path";
		} else if (arg === "--force") {
			force = true;
		} else if (arg.startsWith("--")) {
			return `unknown delete option "${arg}"`;
		} else if (!keySeen) {
			key = arg === "current" ? defaultKey : arg;
			keySeen = true;
		} else {
			return "delete accepts exactly one session key";
		}
	}
	if (output && !exportFormat) exportFormat = "json";
	return { key, confirm, exportFormat, output, force };
}

function requireSessionMethod(ctx: CommandContext, method: string): boolean {
	if (ctx.methods.supports(method)) return true;
	ctx.ui.notice(`daemon does not support ${method}`, "warning");
	return false;
}

function safeSessionFailure(ctx: CommandContext, action: string, error: unknown): void {
	const code =
		error instanceof ControlPlaneError
			? error.code
			: error instanceof NotConnectedError
				? error.code
				: "LOCAL_VALIDATION";
	ctx.ui.notice(
		`session ${action} did not complete (${code}); refresh and retry — no success was recorded`,
		"error",
	);
}

/** Hermes-compatible shorthand for `/session reset`. */
export const resetCommand: SlashCommand = {
	name: "reset",
	summary: "reset the current session and clear its visible transcript",
	group: "sessions",
	methods: [METHOD.sessionsReset],
	async run(ctx) {
		await ctx.methods.sessionsReset({ sessionKey: ctx.session.key });
		ctx.ui.resetSession?.(ctx.session.key);
		ctx.ui.notice(`reset ${ctx.session.key} (history cleared here and on the daemon)`);
	},
};

export const resumeCommand: SlashCommand = {
	name: "resume",
	summary: "replay a session's stored history into the transcript",
	usage: "[key] [count]",
	group: "sessions",
	methods: [METHOD.chatHistory],
	async run(ctx, argv) {
		const key = argv[0] && !/^\d+$/.test(argv[0]) ? argv[0] : ctx.session.key;
		const countArg = argv.find((arg) => /^\d+$/.test(arg));
		const limit = countArg ? Math.min(Number.parseInt(countArg, 10), 200) : 50;
		// Resuming another session is a switch, and the switch already hydrates
		// from stored history — replaying it into *this* transcript instead would
		// mix two sessions' messages under one key.
		if (key !== ctx.session.key && ctx.ui.switchSession) {
			await ctx.ui.switchSession(key);
			ctx.ui.notice(`switched to ${key}`);
			return;
		}
		const result = await ctx.methods.chatHistory({
			sessionKey: key,
			limit,
			includeFullText: true,
		});
		const messages = (result?.messages ?? []) as ChatHistoryMessage[];
		if (messages.length === 0) {
			ctx.ui.notice(`no stored history for ${key}`);
			return;
		}
		ctx.ui.replayHistory(messages);
		ctx.ui.notice(`replayed ${messages.length} message(s) from ${key}`);
	},
};

export const historyCommand: SlashCommand = {
	name: "history",
	summary: "summarize recent messages without replaying them",
	usage: "[count]",
	group: "sessions",
	methods: [METHOD.chatHistory],
	async run(ctx, argv) {
		const requested = Number.parseInt(argv[0] ?? "", 10);
		const limit =
			Number.isFinite(requested) && requested > 0 ? Math.min(requested, 200) : HISTORY_DEFAULT;
		const result = await ctx.methods.chatHistory({
			sessionKey: ctx.session.key,
			limit,
			includeFullText: false,
		});
		const messages = (result?.messages ?? []) as ChatHistoryMessage[];
		if (messages.length === 0) {
			ctx.ui.notice(`no stored history for ${ctx.session.key}`);
			return;
		}
		const lines = [`history of ${ctx.session.key} — last ${messages.length}`];
		for (const message of messages) {
			const when = humanTime(message.timestampMs ?? undefined);
			const body = oneLine(message.content ?? "");
			lines.push(`${when ? `${when} ` : ""}${message.role}: ${body}`);
		}
		ctx.ui.noticeBlock(lines);
	},
};

/** Collapse a message to a single readable line for list output. */
function oneLine(text: string, max = 100): string {
	const flat = text.replace(/\s+/g, " ").trim();
	return flat.length > max ? `${flat.slice(0, max - 1)}…` : flat;
}

/** Exported for tests: the shape `/sessions` turns a summary into. */
export function sessionRowsFrom(result: unknown): SessionSummary[] {
	return asArray(asRecord(result)?.sessions) as SessionSummary[];
}
