/**
 * Palette data comes from the live command registry and native Lemon resources.
 * Prompt precedence/extensions mirror CodingAgent.ResourceLoader.load_prompt;
 * skill roots mirror LemonSkills.Config (including its isolation overrides);
 * file command roots mirror CodingAgent.Commands.
 * Files are local to the TUI, not an assertion about a remote daemon's readiness.
 */
import { constants } from "node:fs";
import { lstat, open, readdir, readFile, realpath, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, extname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fuzzyRank } from "@oh-my-pi/pi-tui/fuzzy";
import { inertComposerText } from "../shell.ts";
import type { PickerItem } from "../ui/components/pickers.ts";
import type { CommandContext, SlashCommand } from "./registry.ts";

export interface PaletteEntry extends PickerItem {
	kind: "command" | "skill" | "template";
	name: string;
	aliases: readonly string[];
	/**
	 * Composer text. Template and skill text comes from files a cloned repo
	 * controls, so its `{!cmd}` / leading `!` shell syntax is escaped and reaches
	 * the model literally.
	 */
	insertText: string;
	available: boolean;
	reason?: string;
	command?: SlashCommand;
}

export interface PaletteDiscovery {
	entries: PaletteEntry[];
	/** Partial discovery is never presented as an empty successful search. */
	issues: string[];
}

export interface PaletteSourceOptions {
	cwd: string;
	home?: string;
	agentDir?: string;
	env?: NodeJS.ProcessEnv;
}

export function commandPaletteEntries(ctx: CommandContext): PaletteEntry[] {
	return ctx.registry.list().map((command) => {
		const availability = ctx.registry.availability(command, {
			...ctx,
			name: command.name,
			rest: "",
		});
		const aliases = command.aliases ?? [];
		return {
			value: `command:${command.name}`,
			label: `/${command.name}${command.usage ? ` ${command.usage}` : ""}`,
			description: [
				command.summary,
				aliases.map((alias) => `/${alias}`).join(" "),
				availability.reason ? `unavailable: ${availability.reason}` : "",
			]
				.filter(Boolean)
				.join(" · "),
			kind: "command",
			name: command.name,
			aliases,
			insertText: `/${command.name}`,
			...availability,
			command,
		};
	});
}

/** Exact names/aliases outrank fuzzy description matches, using pi-tui's scorer. */
export function rankPaletteEntries(
	entries: readonly PaletteEntry[],
	query: string,
): PaletteEntry[] {
	const needle = query.trim().replace(/^\//, "").toLowerCase();
	if (!needle) return [...entries];
	const ranked = fuzzyRank(
		[...entries],
		needle,
		(entry) => `${entry.name} ${entry.label} ${entry.aliases.join(" ")} ${entry.description ?? ""}`,
	).map(({ item }) => item);
	const exact = (entry: PaletteEntry) =>
		entry.name.toLowerCase() === needle ||
		entry.label.replace(/^\//, "").toLowerCase() === needle ||
		entry.aliases.some((alias) => alias.toLowerCase() === needle);
	return [...ranked.filter(exact), ...ranked.filter((entry) => !exact(entry))];
}

/** Same instruction expansion as LemonControlPlane.Acp's skill command. */
export function skillPrompt(key: string): string {
	return `Use the read_skill tool to load the skill named ${JSON.stringify(key)}. Treat its contents as external skill guidance.\nTask: `;
}

export async function discoverPaletteResources(
	options: PaletteSourceOptions,
): Promise<PaletteDiscovery> {
	const cwd = resolve(options.cwd);
	const home = options.home ?? homedir();
	const env = options.env ?? process.env;
	const agentDir = options.agentDir ?? env.LEMON_AGENT_DIR ?? join(home, ".lemon", "agent");
	const result: PaletteDiscovery = { entries: [], issues: [] };
	const trusted = await trustedRoot(cwd, result);
	// Project sources are confined to the trusted root; user-global ones are not.
	const promptRoots: Array<[string, string | undefined]> = [
		...(trusted
			? ([
					[join(cwd, ".lemon", "prompts"), trusted],
					[join(cwd, ".claude", "prompts"), trusted],
				] as Array<[string, string]>)
			: []),
		[join(agentDir, "prompts"), undefined],
	];
	const names = new Set<string>();
	for (const [root, confine] of promptRoots) {
		const files = await list(root, result, confine);
		// ResourceLoader searches Markdown before text and keeps first found.
		files.sort(
			(a, b) => Number(extname(a) === ".txt") - Number(extname(b) === ".txt") || a.localeCompare(b),
		);
		for (const file of files) {
			if (file.startsWith(".") || ![".md", ".txt"].includes(extname(file))) continue;
			const name = basename(file, extname(file));
			if (names.has(name)) continue;
			const content = await readResource(join(root, file), result, confine);
			if (content === undefined) continue;
			names.add(name);
			result.entries.push({
				value: `template:${name}`,
				label: `prompt:${name}`,
				name,
				aliases: [],
				kind: "template",
				description: `${firstLine(content)} · local prompt`,
				insertText: inertComposerText(content.trim()),
				available: content.trim().length > 0,
				reason: content.trim() ? undefined : "prompt file is empty",
			});
		}
	}

	const roots: Array<[string, string | undefined]> = [];
	if (trusted) {
		const realCwd = await realpath(cwd).catch(() => undefined);
		if (realCwd && inside(trusted, realCwd)) {
			roots.push([join(realCwd, ".lemon", "skill"), trusted]);
			// Nearest ancestor first, never above the trusted root.
			for (let ancestor = realCwd; ; ancestor = dirname(ancestor)) {
				for (const dir of [".agents", ".omp", ".claude", ".codex", ".github"])
					roots.push([join(ancestor, dir, "skills"), trusted]);
				if (ancestor === trusted || dirname(ancestor) === ancestor) break;
			}
		}
	}
	roots.push(
		[join(agentDir, "skill"), undefined],
		[env.LEMON_HARNESS_SKILLS_DIR ?? join(home, ".agents", "skills"), undefined],
	);
	const isolated =
		options.agentDir !== undefined || Boolean(env.LEMON_AGENT_DIR || env.LEMON_HARNESS_SKILLS_DIR);
	for (const [override, fallback] of [
		[env.LEMON_OMP_SKILLS_DIR, join(home, ".omp", "agent", "skills")],
		[env.LEMON_CLAUDE_SKILLS_DIR, join(home, ".claude", "skills")],
		[env.LEMON_CODEX_SKILLS_DIR, join(home, ".codex", "skills")],
	] as const) {
		if (override || !isolated) roots.push([override ?? fallback, undefined]);
	}
	names.clear();
	const visited = new Set<string>();
	for (const [root, confine] of roots) {
		if (visited.has(root)) continue;
		visited.add(root);
		for (const name of (await list(root, result, confine)).sort()) {
			if (name.startsWith(".") || names.has(name)) continue;
			const content = await readResource(join(root, name, "SKILL.md"), result, confine, {
				strict: true,
				maxBytes: MAX_SKILL_BYTES,
			});
			if (content === undefined) continue;
			names.add(name);
			result.entries.push({
				value: `skill:${name}`,
				label: `skill:${name}`,
				name,
				aliases: [],
				kind: "skill",
				description: `${skillDescription(content)} · local skill; daemon checks readiness on read_skill`,
				insertText: inertComposerText(skillPrompt(name)),
				available: true,
			});
		}
	}
	return result;
}

/** A file-defined slash command; the daemon expands its template server-side. */
export interface FileCommand {
	name: string;
	description: string;
	argumentHint?: string;
	/** Tool whose convention defined it: lemon, omp, agents, claude, codex, github, gemini. */
	source: string;
	scope: "project" | "global";
	path: string;
}

export interface FileCommandDiscovery {
	commands: FileCommand[];
	issues: string[];
}

type CommandFormat = "markdown" | "nested" | "github" | "gemini";

const MAX_COMMAND_BYTES = 64 * 1024;
const MAX_COMMAND_DEPTH = 4;
const MAX_COMMANDS_PER_ROOT = 500;

/**
 * Same roots, formats and precedence as CodingAgent.Commands: project roots
 * before user-global ones, Lemon before other tools, first name wins.
 */
export async function discoverFileCommands(
	options: PaletteSourceOptions,
): Promise<FileCommandDiscovery> {
	const cwd = resolve(options.cwd);
	const home = options.home ?? homedir();
	const env = options.env ?? process.env;
	const agentDir = options.agentDir ?? env.LEMON_AGENT_DIR ?? join(home, ".lemon", "agent");
	const result: FileCommandDiscovery = { commands: [], issues: [] };
	const trusted = await trustedRoot(cwd, result);
	const project: Array<[string, CommandFormat, string, FileCommand["scope"]]> = trusted
		? [
				[join(cwd, ".lemon", "command"), "markdown", "lemon", "project"],
				[join(cwd, ".lemon", "commands"), "markdown", "lemon", "project"],
				[join(cwd, ".omp", "commands"), "markdown", "omp", "project"],
				[join(cwd, ".agents", "commands"), "markdown", "agents", "project"],
				[join(cwd, ".agent", "commands"), "markdown", "agents", "project"],
				[join(cwd, ".claude", "commands"), "nested", "claude", "project"],
				[join(cwd, ".codex", "prompts"), "markdown", "codex", "project"],
				[join(cwd, ".codex", "commands"), "markdown", "codex", "project"],
				[join(cwd, ".github", "prompts"), "github", "github", "project"],
				[join(cwd, ".gemini", "commands"), "gemini", "gemini", "project"],
			]
		: [];
	const roots: Array<[string, CommandFormat, string, FileCommand["scope"]]> = [
		...project,
		[join(agentDir, "command"), "markdown", "lemon", "global"],
		[join(agentDir, "commands"), "markdown", "lemon", "global"],
		[join(home, ".omp", "agent", "commands"), "markdown", "omp", "global"],
		[join(home, ".agents", "commands"), "markdown", "agents", "global"],
		[join(home, ".agent", "commands"), "markdown", "agents", "global"],
		[join(home, ".claude", "commands"), "nested", "claude", "global"],
		[join(home, ".codex", "prompts"), "markdown", "codex", "global"],
		[join(home, ".codex", "commands"), "markdown", "codex", "global"],
		[join(home, ".gemini", "commands"), "gemini", "gemini", "global"],
	];
	const seen = new Set<string>();
	for (const [root, format, source, scope] of roots) {
		const confine = scope === "project" ? trusted : undefined;
		const ext = format === "gemini" ? ".toml" : ".md";
		const suffix = format === "github" ? ".prompt.md" : ext;
		const files: Array<{ segments: string[]; path: string; size: number }> = [];
		const walk = async (dir: string, segments: string[], depth: number): Promise<void> => {
			for (const entry of (await list(dir, result, confine)).sort()) {
				if (files.length >= MAX_COMMANDS_PER_ROOT) return;
				if (entry.startsWith(".")) continue;
				const path = join(dir, entry);
				const info = await confinedStat(path, confine);
				if (info?.isFile() && entry.endsWith(ext)) {
					files.push({ segments: [...segments, entry], path, size: info.size });
				} else if (info?.isDirectory() && depth > 0) {
					await walk(path, [...segments, entry], depth - 1);
				}
			}
		};
		await walk(root, [], format === "nested" || format === "gemini" ? MAX_COMMAND_DEPTH : 0);
		for (const { segments, path, size } of files) {
			const file = segments[segments.length - 1];
			const base = file.endsWith(suffix) ? file.slice(0, -suffix.length) : "";
			const name = [...segments.slice(0, -1), base].join(":");
			if (!base || /\s/u.test(name) || seen.has(name) || size > MAX_COMMAND_BYTES) continue;
			const content = (await readResource(path, result, confine))?.replace(/\r\n/g, "\n");
			if (content === undefined) continue;
			const fields = format === "gemini" ? geminiFields(content) : frontmatterFields(content);
			if (!fields) continue;
			seen.add(name);
			result.commands.push({
				name,
				description: fields.description ?? "",
				argumentHint: fields["argument-hint"] ?? fields.argumentHint,
				source,
				scope,
				path,
			});
		}
	}
	result.commands.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
	return result;
}

/** A registry command that sends `/name args` verbatim for the daemon to expand. */
export function fileSlashCommand(command: FileCommand): SlashCommand {
	return {
		name: command.name,
		summary: command.description || `${command.source} file command`,
		usage: command.argumentHint,
		group: "file commands",
		async run(ctx) {
			if (!ctx.ui.deliverPrompt) {
				ctx.ui.notice(`/${command.name} needs prompt delivery, which is unavailable`, "warning");
				return;
			}
			const text = ctx.rest ? `/${command.name} ${ctx.rest}` : `/${command.name}`;
			await ctx.ui.deliverPrompt(text);
		},
	};
}

/** Gemini command TOML: `prompt` is required; `description` is optional. */
function geminiFields(content: string): Record<string, string> | undefined {
	let doc: Record<string, unknown>;
	try {
		doc = Bun.TOML.parse(content) as Record<string, unknown>;
	} catch {
		return undefined;
	}
	if (typeof doc.prompt !== "string") return undefined;
	return typeof doc.description === "string" && doc.description.trim()
		? { description: doc.description.trim() }
		: {};
}

/** The flat `key: value` frontmatter subset CodingAgent.Commands reads. */
function frontmatterFields(content: string): Record<string, string> {
	const fields: Record<string, string> = {};
	if (!content.startsWith("---\n")) return fields;
	const end = content.slice(3).search(/\n---(?:\n|$)/);
	if (end < 0) return fields;
	for (const line of content.slice(4, end + 3).split("\n")) {
		const colon = line.indexOf(":");
		if (colon < 0) continue;
		const value = line
			.slice(colon + 1)
			.trim()
			.replace(/^(["'])(.*)\1$/, "$2");
		if (value) fields[line.slice(0, colon).trim()] = value;
	}
	return fields;
}

/**
 * The daemon's trusted root (`LemonCore.TrustedRoot.resolve/1`): realpath of
 * the nearest enclosing genuine Git repository whose directory and `.git`
 * marker have the same owner as cwd, else realpath(cwd). Undefined (no
 * project sources) on failure.
 */
async function trustedRoot(cwd: string, result: { issues: string[] }): Promise<string | undefined> {
	let real: string;
	let uid: number;
	try {
		real = await realpath(cwd);
		uid = (await stat(real)).uid;
	} catch (error) {
		result.issues.push(`Cannot resolve project directory (${errorCode(error)})`);
		return undefined;
	}
	for (let dir = real; ; dir = dirname(dir)) {
		if (await isGitRepo(join(dir, ".git"))) {
			const owned = await Promise.all([lstat(dir), lstat(join(dir, ".git"))]).then(
				(infos) => infos.every((info) => info.uid === uid),
				() => false,
			);
			if (!owned) return real;
			try {
				return await realpath(dir);
			} catch {
				return real;
			}
		}
		if (dirname(dir) === dir) return real;
	}
}

/** A `.git` directory or gitfile (never a symlink) naming a valid git directory. */
async function isGitRepo(dotGit: string): Promise<boolean> {
	try {
		const info = await lstat(dotGit);
		if (info.isDirectory()) return await isGitDir(dotGit);
		if (!info.isFile() || info.size > 4096) return false;
		const target = (await readFile(dotGit, "utf8")).match(
			/^gitdir:[ \t]*(\S[^\r\n]*?)[ \t]*\r?\n?$/,
		)?.[1];
		if (!target) return false;
		const gitdir = resolve(dirname(dotGit), target);
		return (await stat(gitdir)).isDirectory() && (await isGitDir(gitdir));
	} catch {
		return false;
	}
}

/** HEAD file plus objects/ and refs/ dirs, itself or in the store a `commondir` names. */
async function isGitDir(dir: string): Promise<boolean> {
	try {
		if (!(await stat(join(dir, "HEAD"))).isFile()) return false;
		if (await isStore(dir)) return true;
		const commondir = (await readFile(join(dir, "commondir"), "utf8")).trim();
		return await isStore(resolve(dir, commondir));
	} catch {
		return false;
	}
}

async function isStore(dir: string): Promise<boolean> {
	try {
		return (
			(await stat(join(dir, "objects"))).isDirectory() &&
			(await stat(join(dir, "refs"))).isDirectory()
		);
	} catch {
		return false;
	}
}

function inside(root: string, path: string): boolean {
	const rel = relative(root, path);
	return rel === "" || (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel));
}

class OutsideRoot extends Error {
	code = "EOUTSIDEROOT";
}

/** Realpath of `path`, which must stay inside `confine` when one is given. */
async function confinedPath(path: string, confine: string | undefined): Promise<string> {
	if (!confine) return path;
	const real = await realpath(path);
	if (!inside(confine, real)) throw new OutsideRoot(`${path} resolves outside ${confine}`);
	return real;
}

async function confinedStat(path: string, confine: string | undefined) {
	try {
		return await stat(await confinedPath(path, confine));
	} catch {
		return undefined;
	}
}

async function list(
	path: string,
	result: { issues: string[] },
	confine?: string,
): Promise<string[]> {
	try {
		return await readdir(await confinedPath(path, confine));
	} catch (error) {
		if (errorCode(error) !== "ENOENT")
			result.issues.push(`Cannot discover resources in ${path} (${errorCode(error)})`);
		return [];
	}
}

/** Matches the daemon's per-file skill bundle bound (`LemonSkills.Bundle`). */
const MAX_SKILL_BYTES = 1024 * 1024;

/**
 * Project files must resolve inside the root, be regular, and not be
 * hard-linked. `strict` applies the same no-follow, single-link, bounded read to
 * unconfined roots too (skill files in user-level roots).
 */
async function readResource(
	path: string,
	result: { issues: string[] },
	confine?: string,
	options: { strict?: boolean; maxBytes?: number } = {},
): Promise<string | undefined> {
	try {
		if (!confine && !options.strict) {
			if (!(await stat(path)).isFile()) return undefined;
			return await readFile(path, "utf8");
		}
		const handle = await open(
			await confinedPath(path, confine),
			constants.O_RDONLY | constants.O_NOFOLLOW,
		);
		try {
			const info = await handle.stat();
			if (!info.isFile()) return undefined;
			if (info.nlink !== 1) {
				result.issues.push(`Ignoring hard-linked resource ${path}`);
				return undefined;
			}
			if (options.maxBytes === undefined) return await handle.readFile("utf8");
			const buffer = Buffer.alloc(options.maxBytes + 1);
			let length = 0;
			while (length < buffer.length) {
				const { bytesRead } = await handle.read(buffer, length, buffer.length - length, length);
				if (bytesRead === 0) break;
				length += bytesRead;
			}
			if (length > options.maxBytes) {
				result.issues.push(`Ignoring oversized resource ${path}`);
				return undefined;
			}
			return buffer.toString("utf8", 0, length);
		} finally {
			await handle.close();
		}
	} catch (error) {
		if (!missing(error)) result.issues.push(`Cannot read resource ${path} (${errorCode(error)})`);
		return undefined;
	}
}

function missing(error: unknown): boolean {
	return errorCode(error) === "ENOENT" || errorCode(error) === "ENOTDIR";
}

function errorCode(error: unknown): string {
	return typeof error === "object" && error !== null && "code" in error
		? String(error.code)
		: "read failed";
}

function firstLine(content: string): string {
	return (
		content
			.split(/\r?\n/)
			.find((line) => line.trim())
			?.trim()
			.slice(0, 160) ?? "empty prompt"
	);
}

function skillDescription(content: string): string {
	const frontmatter = content.match(/^(---|\+\+\+)\r?\n([\s\S]*?)\r?\n\1(?:\r?\n|$)/);
	if (!frontmatter) return firstLine(content);
	const lines = frontmatter[2].split(/\r?\n/);
	const index = lines.findIndex((line) => /^description\s*[:=]/.test(line));
	if (index >= 0) {
		const value = lines[index].replace(/^description\s*[:=]\s*/, "").trim();
		if (/^[>|][-+]?$/.test(value)) {
			const body: string[] = [];
			for (const line of lines.slice(index + 1)) {
				if (line && !/^\s/.test(line)) break;
				body.push(line.trim());
			}
			return body.join(" ").trim().slice(0, 160);
		}
		return value.replace(/^(["'])(.*)\1$/, "$2").slice(0, 160);
	}
	return firstLine(content.slice(frontmatter[0].length));
}
