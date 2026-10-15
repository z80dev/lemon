import { formatKeyHint } from "@oh-my-pi/pi-tui/key-hint-format";
import { matchesKey } from "@oh-my-pi/pi-tui/keys";
import { CLOSE_ACTION } from "@oh-my-pi/pi-tui/native/picker";
import {
	commandPaletteEntries,
	discoverPaletteResources,
	type PaletteDiscovery,
	type PaletteEntry,
	type PaletteSourceOptions,
	rankPaletteEntries,
} from "../../commands/palette-source.ts";
import { type CommandContext, parseCommandLine } from "../../commands/registry.ts";
import type { NoticeLevel } from "../../store/transcript-model.ts";
import { confirmAction, PickerOverlay, type PickerSheet } from "../components/pickers.ts";
import { LEMON_KEYBINDINGS, type LemonKeybinding } from "./input-controller.ts";

export type CommandPaletteMode = "discovery" | "typed-slash";

export interface CommandPaletteHost {
	/** Resolve at open and selection time so capabilities/session never go stale. */
	context(): CommandContext;
	getDraft(): string;
	setDraft(text: string): void;
	present(overlay: PickerOverlay): () => void;
	repaint(): void;
	notice(text: string, level?: NoticeLevel): void;
	/** Local filesystem configuration, not the daemon's remote/profile workspace. */
	resources?: Omit<PaletteSourceOptions, "cwd">;
}

// Discovery selections execute only read-only actions and existing
// draft-preserving UI entrypoints, never /reset, /quit or /clear.
const IMMEDIATE_COMMANDS: Record<string, true> = {
	profiles: true,
	tree: true,
	editor: true,
	status: true,
	usage: true,
	agents: true,
	approvals: true,
};

/**
 * Commands whose bare invocation does exactly what a global key does, so the
 * native sheet can show the key beside the command.
 */
const COMMAND_KEYS: Record<string, LemonKeybinding> = {
	model: "lemon.picker.model",
	think: "lemon.picker.thinking",
	sessions: "lemon.sessions.switch",
	clear: "lemon.transcript.clear",
	palette: "lemon.palette.open",
	tasktree: "lemon.tasks.toggle",
	omp: "lemon.omp.toggle",
	diff: "lemon.tools.diff",
	copy: "lemon.clipboard.copyLast",
	editor: "lemon.editor.external",
};

const KIND_GROUPS: Record<PaletteEntry["kind"], { id: string; label: string; icon: string }> = {
	command: { id: "command", label: "Commands", icon: "terminal" },
	skill: { id: "skill", label: "Skills", icon: "sparkles" },
	template: { id: "template", label: "Prompts", icon: "doc" },
};

const PALETTE_COLUMNS: PickerSheet["columns"] = [{ id: "keys", format: "dim", priority: 1 }];

/** Native sheet extras: a kind icon and group, the bound key, unavailability. */
function withNative(entries: readonly PaletteEntry[]): PaletteEntry[] {
	return entries.map((entry) => {
		const binding = entry.kind === "command" ? COMMAND_KEYS[entry.name] : undefined;
		const { id, label, icon } = KIND_GROUPS[entry.kind];
		return {
			...entry,
			group: { id, label },
			native: {
				icon,
				...(binding
					? { facts: { keys: formatKeyHint(LEMON_KEYBINDINGS[binding].defaultKeys) } }
					: {}),
				...(entry.available ? {} : { disabled: entry.reason ?? true }),
			},
		};
	});
}

/** Replace only a leading slash query; all remaining draft text survives. */
export function insertPaletteEntry(entry: PaletteEntry, draft: string): string {
	const token = draft.match(/^\s*\/[^\s/]*(?=\s|$)/);
	const remainder = token ? draft.slice(token[0].length).replace(/^[ \t]/, "") : draft;
	if (entry.kind === "command") {
		return `${entry.insertText}${remainder ? ` ${remainder}` : " "}`;
	}
	if (entry.kind === "skill") return `${entry.insertText}${remainder}`;
	return `${entry.insertText}${remainder ? `\n\n${remainder}` : ""}`;
}

export class CommandPalette {
	readonly #host: CommandPaletteHost;
	#overlay: PickerOverlay | undefined;
	#close: (() => void) | undefined;
	#entries: PaletteEntry[] = [];
	#resources: PaletteDiscovery = { entries: [], issues: [] };
	#generation = 0;
	#draft = "";
	#sessionKey = "";
	#loading = false;
	#mode: CommandPaletteMode = "discovery";

	constructor(host: CommandPaletteHost) {
		this.#host = host;
	}

	get overlay(): PickerOverlay | undefined {
		return this.#overlay;
	}

	/** Only a slash typed in an empty editor opts into direct command submission. */
	async open(filter?: string, mode: CommandPaletteMode = "discovery"): Promise<void> {
		this.close();
		const generation = this.#generation;
		const ctx = this.#host.context();
		this.#draft = this.#host.getDraft();
		this.#sessionKey = ctx.session.key;
		this.#resources = { entries: [], issues: [] };
		this.#mode = mode;
		this.#entries = withNative(commandPaletteEntries(ctx));
		this.#loading = true;
		const query = filter ?? this.#draft.match(/^\s*\/([^\s/]*)/)?.[1] ?? "";
		this.#overlay = new PickerOverlay({
			title: "commands · skills · prompts",
			items: rankPaletteEntries(this.#entries, query),
			filter: query,
			// Ranking includes aliases and gives exact aliases priority.
			remoteFilter: true,
			footer:
				mode === "typed-slash"
					? "enter submits exact command / inserts match · esc keeps typed query"
					: "enter inserts / opens action · esc keeps draft",
			detail: () =>
				this.#loading ? "Discovering local skills and prompts…" : this.#resources.issues,
			onFilterChange: (value) => {
				const prefix = value.match(/^(\S+)\s/);
				if (
					this.#mode === "typed-slash" &&
					prefix &&
					this.#host.context().registry.has(prefix[1])
				) {
					this.#restoreTypedQuery(value);
					return;
				}
				this.#overlay?.setItems(rankPaletteEntries(this.#entries, value), value);
				this.#host.repaint();
			},
			onKey: (data) => {
				if (this.#mode !== "typed-slash" || !matchesKey(data, "enter")) return false;
				const item = this.#overlay?.selected;
				if (item) void this.#select(item.value, true);
				return true;
			},
			onSelect: (item) => {
				void this.#select(item.value);
			},
			onCancel: () => {
				if (this.#mode === "typed-slash") {
					this.#restoreTypedQuery(this.#overlay?.filter ?? "");
				} else {
					this.close();
				}
			},
			sheet: {
				icon: "terminal",
				noun: "commands",
				placeholder: "Search commands, skills and prompts…",
				columns: PALETTE_COLUMNS,
				empty: "No command, skill or prompt matches",
				actions: () => [confirmAction(mode === "typed-slash" ? "Submit" : "Insert"), CLOSE_ACTION],
			},
		});
		this.#close = this.#host.present(this.#overlay);
		try {
			const [resources, fileCommandIssues] = await Promise.all([
				discoverPaletteResources({
					...this.#host.resources,
					cwd: ctx.cwd ?? process.cwd(),
				}),
				ctx.registry.refreshFileCommands(),
			]);
			if (generation !== this.#generation) return;
			this.#resources = { ...resources, issues: [...resources.issues, ...fileCommandIssues] };
		} catch {
			if (generation !== this.#generation) return;
			this.#resources = {
				entries: [],
				issues: ["Local resource discovery failed; command results remain available."],
			};
		}
		this.#loading = false;
		this.#entries = withNative([
			...commandPaletteEntries(this.#host.context()),
			...this.#resources.entries,
		]);
		const currentFilter = this.#overlay?.filter ?? query;
		this.#overlay?.setItems(rankPaletteEntries(this.#entries, currentFilter), currentFilter);
		this.#host.repaint();
	}

	/** Also call on session switches/shutdown to ignore outstanding discovery. */
	close(): void {
		this.#generation += 1;
		this.#close?.();
		this.#close = undefined;
		this.#overlay = undefined;
	}

	#checkDraft(ctx: CommandContext): boolean {
		if (ctx.session.key === this.#sessionKey && this.#host.getDraft() === this.#draft) return true;
		this.close();
		this.#host.notice(
			"Draft or session changed; reopen the command palette to insert safely.",
			"warning",
		);
		return false;
	}

	#restoreTypedQuery(query: string): void {
		if (!this.#checkDraft(this.#host.context())) return;
		this.close();
		this.#host.setDraft(`/${query}`);
		this.#host.repaint();
	}

	async #select(value: string, submitTyped = false): Promise<void> {
		const entry = this.#entries.find((candidate) => candidate.value === value);
		if (!entry) return;
		const ctx = this.#host.context();
		if (!this.#checkDraft(ctx)) return;
		const query = this.#overlay?.filter ?? "";
		// Namespaced file commands (`/git:commit`) are not dispatchable lines; they
		// are inserted and sent as prompt text for the daemon to expand.
		const direct =
			submitTyped &&
			entry.command &&
			ctx.registry.get(query) === entry.command &&
			parseCommandLine(`/${query}`) !== null;
		const name = direct ? query.toLowerCase() : entry.name;
		const availability = entry.command
			? ctx.registry.availability(entry.command, { ...ctx, name, rest: "" })
			: entry;
		if (!availability.available) {
			this.#host.notice(
				`${entry.label} is unavailable: ${availability.reason ?? "unavailable"}`,
				"warning",
			);
			return;
		}
		this.close();
		if (direct) {
			this.#host.setDraft("");
			await ctx.registry.dispatch(`/${query}`, ctx);
			return;
		}
		if (entry.command && !entry.command.usage && IMMEDIATE_COMMANDS[entry.name]) {
			// Remove only an exact palette query, not arguments or a prose draft.
			if (/^\s*\/[^\s/]*$/.test(this.#draft)) this.#host.setDraft("");
			await ctx.registry.dispatch(entry.insertText, ctx);
			return;
		}
		this.#host.setDraft(insertPaletteEntry(entry, this.#draft));
		this.#host.repaint();
	}
}
