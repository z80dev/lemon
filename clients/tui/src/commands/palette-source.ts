/**
 * Palette data comes from the live command registry and the daemon: file
 * commands from `commands.list` (the daemon's own discovery, so the palette
 * offers exactly what the daemon expands) and skills from `skills.list`. The
 * client never scans command, prompt or skill roots itself.
 */
import { fuzzyRank } from "@oh-my-pi/pi-tui/fuzzy";
import { describeError } from "../protocol/errors.ts";
import { type ControlPlaneMethods, METHOD } from "../protocol/methods.ts";
import type { DaemonFileCommand } from "../protocol/types.ts";
import { inertComposerText } from "../shell.ts";
import type { PickerItem } from "../ui/components/pickers.ts";
import type { CommandContext, SlashCommand } from "./registry.ts";

export interface PaletteEntry extends PickerItem {
	kind: "command" | "skill";
	name: string;
	aliases: readonly string[];
	/**
	 * Composer text. Skill keys come from files a cloned repo controls, so
	 * `{!cmd}` / leading `!` shell syntax is escaped and reaches the model
	 * literally.
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

/**
 * The file commands the daemon expands for `cwd`, as registry commands. Read
 * fresh on every call, so an added or deleted command file shows on the next
 * refresh. A failed or malformed read throws: the registry then keeps its
 * previous set and reports the issue instead of presenting an empty list.
 */
export async function daemonFileCommands(
	methods: ControlPlaneMethods,
	cwd: string,
): Promise<{ commands: SlashCommand[]; issues: string[] }> {
	if (!methods.supports(METHOD.commandsList)) {
		return { commands: [], issues: ["This daemon does not list file commands (commands.list)."] };
	}
	const result = await methods.commandsList({ cwd });
	if (!Array.isArray(result?.commands)) throw new Error("invalid commands.list result");
	const commands = result.commands.filter(isFileCommand).map(fileSlashCommand);
	return {
		commands,
		issues: result.truncated
			? [`The daemon listed only the first ${commands.length} file commands.`]
			: [],
	};
}

function isFileCommand(value: unknown): value is DaemonFileCommand {
	if (typeof value !== "object" || value === null) return false;
	const { name, description, argumentHint } = value as Record<string, unknown>;
	return (
		typeof name === "string" &&
		name.length > 0 &&
		!/\s/u.test(name) &&
		typeof description === "string" &&
		(argumentHint === null || argumentHint === undefined || typeof argumentHint === "string")
	);
}

/** A registry command that sends `/name args` verbatim for the daemon to expand. */
export function fileSlashCommand(command: DaemonFileCommand): SlashCommand {
	return {
		name: command.name,
		summary: command.description || "file command",
		usage: command.argumentHint ?? undefined,
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

/** Installed skills the daemon serves for `cwd` (`skills.list`); never throws. */
export async function daemonSkillEntries(
	methods: ControlPlaneMethods,
	cwd: string,
): Promise<PaletteDiscovery> {
	if (!methods.supports(METHOD.skillsList)) {
		return { entries: [], issues: ["This daemon does not list skills (skills.list)."] };
	}
	try {
		const result = await methods.skillsList({ cwd });
		if (!Array.isArray(result?.skills)) throw new Error("invalid skills.list result");
		const entries: PaletteEntry[] = [];
		for (const skill of result.skills) {
			const key = typeof skill?.key === "string" ? skill.key : "";
			// Keys are only ever quoted into the instruction, so any name is safe.
			if (!key) continue;
			const enabled = skill.enabled !== false;
			entries.push({
				value: `skill:${key}`,
				label: `skill:${key}`,
				name: key,
				aliases: [],
				kind: "skill",
				description:
					typeof skill.description === "string" && skill.description ? skill.description : "skill",
				insertText: inertComposerText(skillPrompt(key)),
				available: enabled,
				reason: enabled ? undefined : "skill is disabled",
			});
		}
		return {
			entries,
			issues: result.summary?.truncated
				? [`The daemon listed only the first ${entries.length} skills.`]
				: [],
		};
	} catch (error) {
		return { entries: [], issues: [`Skill discovery failed (${describeError(error)})`] };
	}
}
