/**
 * First-class user-managed profile UX.
 *
 * The daemon remains the only profile store. This module renders its roster,
 * opens the stable canonical chat returned by the daemon, and delegates every
 * lifecycle mutation back to the matching `profiles.*` method. In particular,
 * it never accepts a workspace/home path: those boundaries are derived from
 * the validated profile id by `LemonCore.ProfileStore`.
 */

import { METHOD } from "../protocol/methods.ts";
import type { LemonProfile, ProfileCreateParams, ProfileRosterEntry } from "../protocol/types.ts";
import { asRecord, pickNumber, pickString } from "./format.ts";
import type { CommandContext, PickerChoice, SlashCommand } from "./registry.ts";

const PROFILE_ATTR_FLAGS = new Map<string, keyof Omit<ProfileCreateParams, "id">>([
	["--name", "name"],
	["--description", "description"],
	["--avatar", "avatar"],
	["--model", "model"],
	["--system-prompt", "systemPrompt"],
	["--node", "node"],
]);

export const profilesCommand: SlashCommand = {
	name: "profiles",
	summary: "browse profiles and open their canonical chats",
	group: "profiles",
	methods: [METHOD.profilesRoster],
	async run(ctx) {
		await openProfilesPicker(ctx);
	},
};

export const profileCommand: SlashCommand = {
	name: "profile",
	summary: "open, chat with, or manage a Lemon profile",
	usage: "[help|list|current|show|open|chat|create|clone|rename|export|delete] …",
	group: "profiles",
	methods: [METHOD.profilesRoster],
	async run(ctx, argv) {
		const action = (argv[0] ?? "current").toLowerCase();
		switch (action) {
			case "help":
				renderProfileHelp(ctx);
				return;
			case "list":
				await openProfilesPicker(ctx);
				return;
			case "current":
				await showCurrent(ctx);
				return;
			case "show":
				await showProfile(ctx, argv[1]);
				return;
			case "open":
			case "select":
				await openById(ctx, argv[1]);
				return;
			case "chat":
				await chat(ctx, argv);
				return;
			case "create":
				await create(ctx, argv);
				return;
			case "clone":
				await clone(ctx, argv);
				return;
			case "rename":
				await rename(ctx, argv);
				return;
			case "export":
				await exportProfile(ctx, argv);
				return;
			case "delete":
				await deleteProfile(ctx, argv);
				return;
			default:
				ctx.ui.notice(`usage: /profile ${profileCommand.usage}`, "error");
		}
	},
};

export async function loadProfileRoster(ctx: CommandContext): Promise<ProfileRosterEntry[]> {
	const result = await ctx.methods.profilesRoster();
	return (result.profiles ?? []).flatMap((value) => {
		const profile = normalizeRosterEntry(value);
		return profile ? [profile] : [];
	});
}

export function profileChoice(profile: ProfileRosterEntry, focusedKey: string): PickerChoice {
	const current = profile.canonicalSessionKey === focusedKey;
	const node = profile.node || "local";
	const route = node === "local" ? profile.availability : `${node} · ${profile.availability}`;
	const details = [
		current ? "current" : undefined,
		profile.id,
		route,
		profile.model || "default model",
		oneLine(profile.description),
	].filter((part): part is string => Boolean(part));
	return {
		value: profile.id,
		label: profile.name === profile.id ? profile.id : `${profile.name} (${profile.id})`,
		description: details.join(" · "),
	};
}

async function openProfilesPicker(ctx: CommandContext): Promise<void> {
	const profiles = await loadProfileRoster(ctx);
	if (profiles.length === 0) {
		ctx.ui.notice("no user-managed profiles · /profile create <id> to add one");
		return;
	}
	ctx.ui.openPicker({
		title: "profiles",
		items: profiles.map((profile) => profileChoice(profile, ctx.store.focusedKey)),
		footer: "type to filter · enter opens canonical chat · esc cancels",
		onSelect: async (choice) => {
			const profile = profiles.find((candidate) => candidate.id === choice.value);
			if (profile) await openCanonicalChat(ctx, profile);
		},
	});
}

async function showCurrent(ctx: CommandContext): Promise<void> {
	const profiles = await loadProfileRoster(ctx);
	const current = profiles.find((profile) => profile.canonicalSessionKey === ctx.store.focusedKey);
	if (!current) {
		ctx.ui.notice(
			`session ${ctx.store.focusedKey} is not a managed profile chat · /profiles to choose one`,
		);
		return;
	}
	renderProfile(ctx, current, true);
}

async function showProfile(ctx: CommandContext, id: string | undefined): Promise<void> {
	if (!id) {
		await showCurrent(ctx);
		return;
	}
	if (!requireMethod(ctx, METHOD.profilesGet)) return;
	const result = await ctx.methods.profilesGet({ id });
	renderProfile(ctx, result.profile, result.profile.canonicalSessionKey === ctx.store.focusedKey);
}

async function openById(ctx: CommandContext, id: string | undefined): Promise<void> {
	if (!id) {
		ctx.ui.notice("usage: /profile open <id>", "error");
		return;
	}
	if (!requireMethod(ctx, METHOD.profilesGet)) return;
	const result = await ctx.methods.profilesGet({ id });
	await openCanonicalChat(ctx, result.profile);
}

async function chat(ctx: CommandContext, argv: string[]): Promise<void> {
	const id = argv[1];
	const prompt = argv.slice(2).join(" ").trim();
	if (!id || !prompt) {
		ctx.ui.notice("usage: /profile chat <id> <prompt…>", "error");
		return;
	}
	if (!requireMethod(ctx, METHOD.profilesGet) || !requireMethod(ctx, METHOD.profileChat)) return;
	const result = await ctx.methods.profilesGet({ id });
	await openCanonicalChat(ctx, result.profile, false);
	if (!ctx.ui.deliverPrompt) {
		ctx.ui.notice("this build cannot submit profile chat", "warning");
		return;
	}
	await ctx.ui.deliverPrompt(prompt, ctx.store.submissionMode);
}

async function create(ctx: CommandContext, argv: string[]): Promise<void> {
	const id = argv[1];
	if (!id) {
		ctx.ui.notice(`usage: ${createUsage()}`, "error");
		return;
	}
	if (!requireMethod(ctx, METHOD.profilesCreate)) return;
	const parsed = parseProfileAttrs(argv.slice(2));
	if (typeof parsed === "string") {
		ctx.ui.notice(`${parsed} · usage: ${createUsage()}`, "error");
		return;
	}
	const result = await ctx.methods.profilesCreate({ id, ...parsed });
	await openCanonicalChat(ctx, result.profile, false);
	ctx.ui.notice(
		`created ${displayName(result.profile)} · opened ${result.profile.canonicalSessionKey}`,
	);
}

async function clone(ctx: CommandContext, argv: string[]): Promise<void> {
	const sourceId = argv[1];
	const id = argv[2];
	if (!sourceId || !id) {
		ctx.ui.notice(`usage: ${cloneUsage()}`, "error");
		return;
	}
	if (!requireMethod(ctx, METHOD.profilesClone)) return;
	const parsed = parseProfileAttrs(argv.slice(3));
	if (typeof parsed === "string") {
		ctx.ui.notice(`${parsed} · usage: ${cloneUsage()}`, "error");
		return;
	}
	const result = await ctx.methods.profilesClone({ sourceId, id, ...parsed });
	await openCanonicalChat(ctx, result.profile, false);
	ctx.ui.notice(
		`cloned ${sourceId} to ${displayName(result.profile)} · opened ${result.profile.canonicalSessionKey}`,
	);
}

async function rename(ctx: CommandContext, argv: string[]): Promise<void> {
	const id = argv[1];
	const name = argv.slice(2).join(" ").trim();
	if (!id || !name) {
		ctx.ui.notice("usage: /profile rename <id> <new name…>", "error");
		return;
	}
	if (!requireMethod(ctx, METHOD.profilesRename)) return;
	const result = await ctx.methods.profilesRename({ id, name });
	ctx.ui.notice(
		`renamed ${id} to ${result.profile.name} · canonical chat remains ${result.profile.canonicalSessionKey}`,
	);
}

async function exportProfile(ctx: CommandContext, argv: string[]): Promise<void> {
	const id = argv[1];
	const path = argv[2];
	const tail = argv.slice(3);
	const force = tail.includes("--force");
	if (!id || !path || path.startsWith("--") || tail.some((arg) => arg !== "--force")) {
		ctx.ui.notice("usage: /profile export <id> <output-path> [--force]", "error");
		return;
	}
	if (!requireMethod(ctx, METHOD.profilesExport)) return;
	const result = await ctx.methods.profilesExport({ id, path, ...(force ? { force: true } : {}) });
	const exported = asRecord(result.export);
	ctx.ui.noticeBlock([
		`exported ${id} to ${pickString(exported, "path") ?? path}`,
		`${pickNumber(exported, "fileCount") ?? 0} file(s) · ${pickNumber(exported, "redactionCount") ?? 0} redaction(s) · sessions, memory, and credentials excluded`,
	]);
}

async function deleteProfile(ctx: CommandContext, argv: string[]): Promise<void> {
	const id = argv[1];
	const confirm = confirmationValue(argv.slice(2));
	if (!id) {
		ctx.ui.notice("usage: /profile delete <id> --confirm <id>", "error");
		return;
	}
	if (confirm !== id) {
		ctx.ui.notice(
			`deletion is recoverable but removes the profile record · confirm with /profile delete ${id} --confirm ${id}`,
			"warning",
		);
		return;
	}
	if (!requireMethod(ctx, METHOD.profilesDelete)) return;
	const result = await ctx.methods.profilesDelete({ id, confirm });
	const deleted = asRecord(result.deleted) ?? {};
	const sessionKey = pickString(deleted, "canonicalSessionKey") ?? `agent:${id}:main`;
	ctx.ui.forgetProfile?.(id, sessionKey);
	if (ctx.store.focusedKey === sessionKey && ctx.ui.createSession) {
		await ctx.ui.createSession();
	}
	ctx.ui.notice(
		`deleted ${id}${deleted.homeMoved === true ? " · managed home moved to trash" : ""}`,
		"warning",
	);
}

async function openCanonicalChat(
	ctx: CommandContext,
	profile: LemonProfile,
	announce = true,
): Promise<void> {
	if (!profile.canonicalSessionKey) {
		ctx.ui.notice(`profile ${profile.id} has no canonical session key`, "error");
		return;
	}
	if (ctx.ui.openProfile) {
		await ctx.ui.openProfile(profile.id, profile.canonicalSessionKey);
	} else if (ctx.ui.switchSession) {
		await ctx.ui.switchSession(profile.canonicalSessionKey);
	} else {
		ctx.ui.notice(`this build cannot open ${profile.canonicalSessionKey}`, "warning");
		return;
	}
	if (announce) {
		ctx.ui.notice(
			`opened ${displayName(profile)} · ${profile.canonicalSessionKey} · ${describeRoute(profile)}`,
		);
	}
}

function renderProfile(ctx: CommandContext, profile: LemonProfile, current: boolean): void {
	ctx.ui.noticeBlock([
		`${displayName(profile)}${current ? " · current" : ""}`,
		`id: ${profile.id} · chat: ${profile.canonicalSessionKey}`,
		`route: ${describeRoute(profile)} · model: ${profile.model || "daemon default"}`,
		...(profile.description ? [profile.description] : []),
	]);
}

function renderProfileHelp(ctx: CommandContext): void {
	ctx.ui.noticeBlock([
		"profile commands",
		"/profiles — browse and open canonical chats",
		"/profile current | show [id] | open <id>",
		"/profile chat <id> <prompt…>",
		createUsage(),
		cloneUsage(),
		"/profile rename <id> <new name…>",
		"/profile export <id> <output-path> [--force]",
		"/profile delete <id> --confirm <id>",
		"profile workspaces are server-derived; no workspace path option exists",
	]);
}

function describeRoute(profile: LemonProfile | ProfileRosterEntry): string {
	const node = profile.node || "local";
	const availability = "availability" in profile ? profile.availability : undefined;
	return availability ? `${node} (${availability})` : node;
}

function displayName(profile: LemonProfile): string {
	return profile.name === profile.id ? profile.id : `${profile.name} (${profile.id})`;
}

function normalizeRosterEntry(value: unknown): ProfileRosterEntry | undefined {
	const record = asRecord(value);
	const id = pickString(record, "id");
	const canonicalSessionKey = pickString(record, "canonicalSessionKey");
	if (!id || !canonicalSessionKey) return undefined;
	return {
		id,
		name: pickString(record, "name") ?? id,
		description: pickString(record, "description"),
		avatar: pickString(record, "avatar"),
		model: pickString(record, "model"),
		node: pickString(record, "node") ?? "local",
		canonicalSessionKey,
		availability: pickString(record, "availability") ?? "offline",
	};
}

function parseProfileAttrs(argv: string[]): Omit<ProfileCreateParams, "id"> | string {
	const attrs: Omit<ProfileCreateParams, "id"> = {};
	for (let index = 0; index < argv.length; index += 1) {
		const raw = argv[index]!;
		const equal = raw.indexOf("=");
		const flag = equal > 0 ? raw.slice(0, equal) : raw;
		const key = PROFILE_ATTR_FLAGS.get(flag);
		if (!key) return `unknown profile option "${flag}"`;
		const value = equal > 0 ? raw.slice(equal + 1) : argv[++index];
		if (!value || (equal < 0 && value.startsWith("--"))) return `${flag} requires a value`;
		attrs[key] = value;
	}
	return attrs;
}

function confirmationValue(argv: string[]): string | undefined {
	if (argv.length === 1 && argv[0]?.startsWith("--confirm=")) {
		return argv[0].slice("--confirm=".length);
	}
	if (argv.length === 2 && argv[0] === "--confirm") return argv[1];
	return undefined;
}

function requireMethod(ctx: CommandContext, method: string): boolean {
	if (ctx.methods.supports(method)) return true;
	ctx.ui.notice(`daemon does not support ${method}`, "warning");
	return false;
}

function createUsage(): string {
	return "/profile create <id> [--name <name>] [--description <text>] [--avatar <value>] [--model <id>] [--system-prompt <text>] [--node <name>]";
}

function cloneUsage(): string {
	return "/profile clone <source-id> <new-id> [--name <name>] [--description <text>] [--avatar <value>] [--model <id>] [--system-prompt <text>] [--node <name>]";
}

function oneLine(value: unknown, max = 80): string | undefined {
	if (typeof value !== "string") return undefined;
	const text = value.replace(/\s+/g, " ").trim();
	if (!text) return undefined;
	return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}
