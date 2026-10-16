import { promises as fsPromises } from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
	addKeyAliases,
	canonicalKeyId,
	type KeybindingDefinitions,
	type KeybindingsConfig,
	KeybindingsManager,
} from "@oh-my-pi/pi-tui/keybindings";
import { Key, type KeyId, parseKey } from "@oh-my-pi/pi-tui/keys";

export type NotificationMode = "auto" | "osc" | "bell" | "off";

/** Environment wins over the global TUI setting; retain the original 0/1 switch. */
export function resolveNotifications(
	configured: unknown,
	env: NodeJS.ProcessEnv = process.env,
): NotificationMode {
	const value = env.LEMON_TUI_NOTIFICATIONS ?? configured;
	if (value === "0") return "off";
	if (value === "osc" || value === "bell" || value === "off") return value;
	return "auto";
}

/**
 * `[tui] prompt_history`: on unless the setting is present and not `true`, so a
 * mistyped opt-out (`"off"`, `"false"`) never leaves prompts on disk.
 */
export function resolvePromptHistory(configured: unknown): boolean {
	return (configured ?? true) === true;
}

/**
 * Whether to persist history given what `loadConfig` produced. A failed load
 * may be hiding an explicit opt-out (a broken project file next to a global
 * `prompt_history = false`), so it disables persistence rather than assuming
 * the default.
 */
export function promptHistoryEnabled(
	config: LemonConfig | undefined,
	loadFailed: boolean,
): boolean {
	return !loadFailed && resolvePromptHistory(config?.tui?.prompt_history);
}

/**
 * The slice of Lemon's `config.toml` the TUI reads. The file belongs to the
 * daemon (`LemonCore.Config`); the TUI reads its own presentation settings and
 * edits single keys in place, never re-serializing the file.
 */
export interface LemonConfig {
	/** Daemon-wide defaults; the model picker's "make default" writes here. */
	defaults?: {
		provider?: string;
		model?: string;
		thinking_level?: string;
	};
	/** Terminal presentation settings (`/theme <name>` writes `theme`). */
	tui?: {
		theme?: string;
		notifications?: NotificationMode;
		/** Persist ↑ recall to `~/.lemon/tui-history/history.sqlite3`; `false` turns it off (default on). */
		prompt_history?: boolean;
		keys?: unknown;
	};
}

/**
 * Get the config directory path (~/.lemon/)
 *
 * `$HOME` is read on every call rather than through Bun's cached `homedir()`,
 * which is what the daemon does (`LemonCore.Paths.home_dir/1`). A client run
 * against a scoped home must read and write the same file the daemon does —
 * and it keeps a test that points `$HOME` at a temp dir off the real config.
 */
export function getConfigDir(): string {
	const home = process.env.HOME?.trim();
	return path.join(home && home.length > 0 ? home : os.homedir(), ".lemon");
}

/**
 * Get the config file path (~/.lemon/config.toml)
 */
export function getConfigPath(): string {
	return path.join(getConfigDir(), "config.toml");
}

/**
 * Get the project config path (<cwd>/.lemon/config.toml)
 */
export function getProjectConfigPath(cwd: string): string {
	return path.join(cwd, ".lemon", "config.toml");
}

/**
 * Load the global config, overlaid with the project config when `cwd` is
 * given. A missing file is an empty config; an unreadable or invalid one throws.
 */
export async function loadConfig(cwd?: string): Promise<LemonConfig> {
	const global = await readConfigFile(getConfigPath());
	if (!cwd) return global;
	const project = await readConfigFile(getProjectConfigPath(cwd));
	return {
		defaults: { ...global.defaults, ...project.defaults },
		tui: {
			...global.tui,
			...project.tui,
			keys: mergeKeyTables(global.tui?.keys, project.tui?.keys),
		},
	};
}

async function readConfigFile(configPath: string): Promise<LemonConfig> {
	const content = await readOptional(configPath);
	if (content === undefined) return {};
	try {
		return Bun.TOML.parse(content) as LemonConfig;
	} catch (err) {
		throw configLoadError(configPath, err);
	}
}

async function readOptional(configPath: string): Promise<string | undefined> {
	try {
		return await fsPromises.readFile(configPath, "utf-8");
	} catch (err) {
		if ((err as NodeJS.ErrnoException | undefined)?.code === "ENOENT") return undefined;
		throw configLoadError(configPath, err);
	}
}

function configLoadError(configPath: string, err: unknown): Error {
	const message = err instanceof Error ? err.message : String(err);
	return new Error(`Failed to load config ${configPath}: ${message}`);
}

function isTable(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function mergeKeyTables(global: unknown, project: unknown): unknown {
	if (project === undefined) return global;
	return isTable(global) && isTable(project) ? { ...global, ...project } : project;
}

/** pi-tui exposes a raw-input parser, not a chord-string validator. Check its
 * exported named keys and parse printable bases; reject malformed modifiers. */
function parseBinding(value: string): KeyId | undefined {
	let rest = value.toLowerCase();
	const modifiers = new Set<string>();
	for (;;) {
		const match = /^(ctrl|shift|alt|super)\+/.exec(rest);
		if (!match) break;
		if (modifiers.has(match[1]!)) return undefined;
		modifiers.add(match[1]!);
		rest = rest.slice(match[0].length);
	}
	const named = Object.values(Key).some(
		(key) => typeof key === "string" && key.toLowerCase() === rest,
	);
	if (!named && !(rest.length === 1 && /^[a-z0-9]$/.test(rest) && parseKey(rest))) {
		return undefined;
	}
	return canonicalKeyId(value.toLowerCase()) as KeyId;
}

/** Ignore invalid overrides as a unit. Conflicting overrides fall back to their
 * defaults, iterating because that fallback can expose another conflict. */
export function resolveKeybindings(
	configured: unknown,
	definitions: KeybindingDefinitions,
): { manager: KeybindingsManager; issues: string[] } {
	const issues: string[] = [];
	const bindings: KeybindingsConfig = {};
	if (configured !== undefined && !isTable(configured)) {
		issues.push("[tui.keys] must be a table");
	}
	for (const [action, value] of Object.entries(isTable(configured) ? configured : {})) {
		if (!Object.hasOwn(definitions, action)) {
			issues.push(`unknown action ${action}`);
			continue;
		}
		if (value === "none") {
			bindings[action] = [];
			continue;
		}
		const values = Array.isArray(value) ? value : [value];
		const keys = values.map((key) => (typeof key === "string" ? parseBinding(key) : undefined));
		if (keys.some((key) => key === undefined)) {
			issues.push(`invalid key for ${action}`);
			continue;
		}
		bindings[action] = keys as KeyId[];
	}
	let manager = new KeybindingsManager(definitions, bindings);
	for (;;) {
		const conflicts = manager.getConflicts();
		// The manager reports user/user conflicts only. Include defaults, using
		// its canonical IDs so aliases and reordered modifiers also collide.
		const claims = new Map<string, string[]>();
		for (const [action, keys] of Object.entries(manager.getResolvedBindings())) {
			const aliases = new Set<string>();
			for (const key of [keys ?? []].flat()) addKeyAliases(aliases, key);
			for (const key of aliases) {
				const actions = claims.get(key) ?? [];
				actions.push(action);
				claims.set(key, actions);
			}
		}
		for (const [key, actions] of claims) {
			if (actions.length > 1 && actions.some((action) => bindings[action] !== undefined)) {
				conflicts.push({ key: key as KeyId, keybindings: actions });
			}
		}
		const rejected = new Set<string>();
		for (const conflict of conflicts) {
			for (const action of conflict.keybindings) {
				if (bindings[action] !== undefined) rejected.add(action);
			}
			const issue = `key ${conflict.key} conflicts: ${conflict.keybindings.join(", ")}`;
			if (!issues.includes(issue)) issues.push(issue);
		}
		if (rejected.size === 0) break;
		for (const action of rejected) delete bindings[action];
		manager = new KeybindingsManager(definitions, bindings);
	}
	return { manager, issues };
}

/**
 * Persist the daemon's default model: `[defaults] provider` and `model`, the
 * same keys `lemon setup provider --set-default` writes. `model` is the
 * picker's `provider:id` selector.
 */
export async function saveDefaultModel(provider: string, model: string): Promise<void> {
	await patchConfig([
		{ table: "defaults", key: "provider", value: provider },
		{ table: "defaults", key: "model", value: model },
	]);
}

/** Persist the TUI theme preference as `[tui] theme`. */
export async function saveTheme(theme: string): Promise<void> {
	await patchConfig([{ table: "tui", key: "theme", value: theme }]);
}

interface StringPatch {
	table: string;
	key: string;
	value: string;
}

/**
 * Upsert string keys in the global config without touching anything else:
 * comments, unknown tables and key order survive. The patched text must still
 * parse before it atomically replaces the file, which keeps its permissions
 * (a new file is created private, like the daemon's).
 */
async function patchConfig(patches: StringPatch[]): Promise<void> {
	const configPath = getConfigPath();
	const original = (await readOptional(configPath)) ?? "";
	const patched = patches.reduce(
		(content, { table, key, value }) => upsertTomlString(content, table, key, value),
		original,
	);
	try {
		Bun.TOML.parse(patched);
	} catch (err) {
		throw new Error(
			`Refusing to write ${configPath}: the edit would not parse (${err instanceof Error ? err.message : String(err)})`,
		);
	}
	await fsPromises.mkdir(path.dirname(configPath), { recursive: true });
	const mode = await fsPromises.stat(configPath).then(
		(stat) => stat.mode & 0o777,
		() => 0o600,
	);
	const temp = path.join(
		path.dirname(configPath),
		`.${path.basename(configPath)}.tmp-${process.pid}-${Date.now()}`,
	);
	try {
		await fsPromises.writeFile(temp, patched, { encoding: "utf-8", mode });
		await fsPromises.chmod(temp, mode);
		await fsPromises.rename(temp, configPath);
	} catch (err) {
		await fsPromises.rm(temp, { force: true });
		throw err;
	}
}

// ── Targeted TOML edits (the TypeScript twin of `LemonCore.Config.TomlPatch`) ──

/**
 * A `[table]` header: quoted segments or anything but brackets and quotes, so
 * `[a] # see [b]` and `[[array]]` are told apart.
 */
const HEADER = /^\s*\[((?:"(?:[^"\\]|\\.)*"|'[^']*'|[^[\]'"])+)\]\s*(?:#.*)?$/;
/** Any table or array-of-tables header: the end of the current section. */
const BOUNDARY = /^\s*\[.*\]\s*(?:#.*)?$/;

/**
 * Parse a dotted TOML key into segments: `providers."openai-codex"` and
 * `providers.openai-codex` are both `["providers", "openai-codex"]`.
 */
export function parseDottedKey(raw: string): string[] | undefined {
	const segments: string[] = [];
	let rest = raw.trim();
	while (true) {
		const match =
			/^"((?:[^"\\]|\\.)*)"/.exec(rest) ?? /^'([^']*)'/.exec(rest) ?? /^[A-Za-z0-9_-]+/.exec(rest);
		if (!match) return undefined;
		const [whole, inner] = match;
		segments.push(
			inner === undefined
				? whole
				: whole.startsWith('"')
					? inner.replace(/\\(["\\])/g, "$1")
					: inner,
		);
		rest = rest.slice(match[0].length).trimStart();
		if (rest === "") return segments;
		if (!rest.startsWith(".")) return undefined;
		rest = rest.slice(1).trimStart();
	}
}

function headerPath(line: string): string[] | undefined {
	const match = HEADER.exec(line);
	return match ? parseDottedKey(match[1]!) : undefined;
}

/**
 * Set `key = "value"` in `[table]`, replacing an existing assignment or
 * appending one to the section. A missing table is added in front of its first
 * `[table.child]` (a parent may not follow its children) or at the end.
 */
export function upsertTomlString(
	content: string,
	table: string,
	key: string,
	value: string,
): string {
	const target = parseDottedKey(table);
	if (!target) throw new Error(`invalid TOML table name: ${table}`);
	const line = `${key} = ${JSON.stringify(value)}`;
	const lines = content.replace(/\r\n/g, "\n").split("\n");
	// Each header's path when it is under `target` (the table itself or a child).
	const under = lines.map((candidate) => {
		const found = headerPath(candidate);
		return found &&
			found.length >= target.length &&
			target.every((segment, i) => found[i] === segment)
			? found
			: undefined;
	});

	const header = under.findIndex((found) => found?.length === target.length);
	if (header === -1) {
		const block = [`[${table}]`, line];
		const child = under.findIndex((found) => found !== undefined);
		if (child !== -1) {
			lines.splice(child, 0, ...block, "");
			return lines.join("\n");
		}
		const body = lines.join("\n");
		if (body.trim() === "") return `${block.join("\n")}\n`;
		return `${body.endsWith("\n") ? body : `${body}\n`}\n${block.join("\n")}\n`;
	}

	let end = lines.findIndex((candidate, i) => i > header && BOUNDARY.test(candidate));
	if (end === -1) end = lines.length;
	const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
	const assignment = new RegExp(`^\\s*${escapedKey}\\s*=`);
	const existing = lines.findIndex(
		(candidate, i) => i > header && i < end && assignment.test(candidate),
	);
	if (existing !== -1) {
		lines[existing] = line;
		return lines.join("\n");
	}
	// After the section's last non-blank line, so a blank separator stays put.
	let insertAt = end;
	while (insertAt - 1 > header && lines[insertAt - 1]!.trim() === "") insertAt -= 1;
	lines.splice(insertAt, 0, line);
	return lines.join("\n");
}
