/**
 * Palette data comes from the live command registry and native Lemon resources.
 * Prompt precedence/extensions mirror CodingAgent.ResourceLoader.load_prompts;
 * skill roots mirror LemonSkills.Config (including its isolation overrides);
 * file command roots mirror CodingAgent.Commands.
 * Files are local to the TUI, not an assertion about a remote daemon's readiness.
 */
import { readdir, readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, extname, join, resolve } from "node:path";
import { fuzzyRank } from "@oh-my-pi/pi-tui/fuzzy";
import type { PickerItem } from "../ui/components/pickers.ts";
import type { CommandContext, SlashCommand } from "./registry.ts";

export interface PaletteEntry extends PickerItem {
	kind: "command" | "skill" | "template";
	name: string;
	aliases: readonly string[];
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
	const promptRoots = [
		join(cwd, ".lemon", "prompts"),
		join(cwd, ".claude", "prompts"),
		join(agentDir, "prompts"),
	];
	const names = new Set<string>();
	for (const root of new Set(promptRoots)) {
		const files = await list(root, result);
		// ResourceLoader searches Markdown before text and keeps first found.
		files.sort(
			(a, b) => Number(extname(a) === ".txt") - Number(extname(b) === ".txt") || a.localeCompare(b),
		);
		for (const file of files) {
			if (file.startsWith(".") || ![".md", ".txt"].includes(extname(file))) continue;
			const name = basename(file, extname(file));
			if (names.has(name)) continue;
			const content = await readResource(join(root, file), result);
			if (content === undefined) continue;
			names.add(name);
			result.entries.push({
				value: `template:${name}`,
				label: `prompt:${name}`,
				name,
				aliases: [],
				kind: "template",
				description: `${firstLine(content)} · local prompt`,
				insertText: content.trim(),
				available: content.trim().length > 0,
				reason: content.trim() ? undefined : "prompt file is empty",
			});
		}
	}

	const roots = [join(cwd, ".lemon", "skill")];
	for (let ancestor = cwd; ; ancestor = dirname(ancestor)) {
		for (const dir of [".agents", ".omp", ".claude", ".codex", ".github"])
			roots.push(join(ancestor, dir, "skills"));
		try {
			await stat(join(ancestor, ".git"));
			break;
		} catch (error) {
			if (!missing(error))
				result.issues.push(`Cannot inspect skill repository boundary (${errorCode(error)})`);
		}
		if (dirname(ancestor) === ancestor) break;
	}
	roots.push(
		join(agentDir, "skill"),
		env.LEMON_HARNESS_SKILLS_DIR ?? join(home, ".agents", "skills"),
	);
	const isolated =
		options.agentDir !== undefined || Boolean(env.LEMON_AGENT_DIR || env.LEMON_HARNESS_SKILLS_DIR);
	for (const [override, fallback] of [
		[env.LEMON_OMP_SKILLS_DIR, join(home, ".omp", "agent", "skills")],
		[env.LEMON_CLAUDE_SKILLS_DIR, join(home, ".claude", "skills")],
		[env.LEMON_CODEX_SKILLS_DIR, join(home, ".codex", "skills")],
	] as const) {
		if (override || !isolated) roots.push(override ?? fallback);
	}
	names.clear();
	for (const root of new Set(roots)) {
		for (const name of (await list(root, result)).sort()) {
			if (name.startsWith(".") || names.has(name)) continue;
			const content = await readResource(join(root, name, "SKILL.md"), result);
			if (content === undefined) continue;
			names.add(name);
			result.entries.push({
				value: `skill:${name}`,
				label: `skill:${name}`,
				name,
				aliases: [],
				kind: "skill",
				description: `${skillDescription(content)} · local skill; daemon checks readiness on read_skill`,
				insertText: skillPrompt(name),
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
	const roots: Array<[string, CommandFormat, string, FileCommand["scope"]]> = [
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
	const result: FileCommandDiscovery = { commands: [], issues: [] };
	const seen = new Set<string>();
	for (const [root, format, source, scope] of roots) {
		const ext = format === "gemini" ? ".toml" : ".md";
		const suffix = format === "github" ? ".prompt.md" : ext;
		const files: Array<{ segments: string[]; path: string; size: number }> = [];
		const walk = async (dir: string, segments: string[], depth: number): Promise<void> => {
			for (const entry of (await list(dir, result)).sort()) {
				if (files.length >= MAX_COMMANDS_PER_ROOT) return;
				if (entry.startsWith(".")) continue;
				const path = join(dir, entry);
				const info = await stat(path).catch(() => undefined);
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
			const content = (await readResource(path, result))?.replace(/\r\n/g, "\n");
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
			await ctx.ui.deliverPrompt(text, ctx.store.submissionMode);
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

async function list(path: string, result: { issues: string[] }): Promise<string[]> {
	try {
		return await readdir(path);
	} catch (error) {
		if (errorCode(error) !== "ENOENT")
			result.issues.push(`Cannot discover resources in ${path} (${errorCode(error)})`);
		return [];
	}
}

async function readResource(
	path: string,
	result: { issues: string[] },
): Promise<string | undefined> {
	try {
		if (!(await stat(path)).isFile()) return undefined;
		return await readFile(path, "utf8");
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
