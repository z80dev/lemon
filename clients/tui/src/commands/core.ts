/**
 * Client-local commands: help, exit, the transcript, the connection, the
 * editor and the theme. Only `/theme` and `/editor` reach outside the process,
 * and neither touches the control plane.
 */

import { saveConfigKey } from "../config.ts";
import { DARK_PALETTE, initTheme, type Palette, peekTheme } from "../ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../ui/theme/tui-adapters.ts";
import { indentBlock } from "./format.ts";
import { describeError, type SlashCommand, SUBMISSION_MODES } from "./registry.ts";

/**
 * Theme registry. P7 owns the light palette and OSC 11 auto-detection; until it
 * lands this is the honest list — one theme, and `/theme` says so rather than
 * pretending a name it cannot install.
 */
export const THEMES: Record<string, { palette: Palette; appearance: "dark" | "light" }> = {
	"lemon-dark": { palette: DARK_PALETTE, appearance: "dark" },
};

export const helpCommand: SlashCommand = {
	name: "help",
	aliases: ["?"],
	summary: "list commands, or explain one",
	usage: "[command]",
	group: "general",
	run(ctx, argv) {
		ctx.ui.noticeBlock(ctx.registry.renderHelp(ctx, argv[0]));
	},
};

export const quitCommand: SlashCommand = {
	name: "quit",
	aliases: ["exit", "q"],
	summary: "leave the client (the daemon keeps running)",
	group: "general",
	run(ctx) {
		ctx.ui.requestExit(0);
	},
};

export const clearCommand: SlashCommand = {
	name: "clear",
	summary: "clear the transcript and the terminal scrollback",
	group: "general",
	run(ctx) {
		ctx.ui.clearTranscript();
	},
};

export const reconnectCommand: SlashCommand = {
	name: "reconnect",
	summary: "drop the control-plane socket and dial again",
	group: "connection",
	run(ctx) {
		ctx.ui.notice("reconnecting…");
		ctx.ui.reconnect();
	},
};

export const debugCommand: SlashCommand = {
	name: "debug",
	summary: "show the last protocol frames",
	usage: "[count]",
	group: "connection",
	run(ctx, argv) {
		const requested = Number.parseInt(argv[0] ?? "", 10);
		const limit = Number.isFinite(requested) && requested > 0 ? Math.min(requested, 200) : 30;
		const frames = ctx.ui.frameLog().slice(-limit);
		const header = [
			`connection ${ctx.client.state} · ${ctx.client.url}`,
			`client id ${ctx.client.clientId} · ${ctx.store.methods.size} methods advertised`,
			`last ${frames.length} frame(s)`,
		];
		ctx.ui.noticeBlock(
			frames.length > 0 ? [...header, ...frames] : [...header, "(no traffic yet)"],
		);
	},
};

export const modeCommand: SlashCommand = {
	name: "mode",
	summary: "how a prompt submitted during a run is handled",
	usage: "[queue|steer|interrupt]",
	group: "general",
	run(ctx, argv) {
		const requested = argv[0]?.toLowerCase();
		if (!requested) {
			ctx.ui.noticeBlock([
				`submission mode: ${ctx.store.submissionMode}`,
				"queue — hold the prompt until the run finishes, then send it",
				"steer — send it into the running turn",
				"interrupt — stop the run and send it",
			]);
			return;
		}
		const mode = SUBMISSION_MODES.find((candidate) => candidate === requested);
		if (!mode) {
			ctx.ui.notice(`unknown mode "${requested}" (${SUBMISSION_MODES.join(", ")})`, "error");
			return;
		}
		ctx.store.setSubmissionMode(mode);
		ctx.ui.refreshStatus();
		ctx.ui.notice(`submission mode: ${mode}`);
	},
};

export const themeCommand: SlashCommand = {
	name: "theme",
	summary: "switch the color theme",
	usage: "[name]",
	group: "general",
	async run(ctx, argv) {
		const names = Object.keys(THEMES);
		const requested = argv[0]?.toLowerCase();
		if (!requested) {
			const current = peekTheme()?.name ?? "(none)";
			ctx.ui.noticeBlock([`theme: ${current}`, `available: ${names.join(", ")}`]);
			return;
		}
		const entry = THEMES[requested];
		if (!entry) {
			ctx.ui.notice(`unknown theme "${requested}" (available: ${names.join(", ")})`, "error");
			return;
		}
		initTheme({ name: requested, appearance: entry.appearance, palette: entry.palette });
		invalidateThemeAdapters();
		ctx.ui.themeChanged?.();
		ctx.ui.notice(`theme: ${requested}`);
		try {
			await saveConfigKey("agent", { theme: requested });
		} catch (error) {
			ctx.ui.notice(`theme not persisted: ${describeError(error)}`, "warning");
		}
	},
};

/**
 * `/editor` hands the draft to $EDITOR. The handoff itself (terminal suspend,
 * spawn, restore) lives in {@link "../external-editor.ts"}; the host wires it
 * to this command so the command stays free of pi-tui.
 */
export function makeEditorCommand(open: () => Promise<void>): SlashCommand {
	return {
		name: "editor",
		summary: "edit the draft in $EDITOR (also Ctrl+G)",
		group: "general",
		async run(ctx) {
			try {
				await open();
			} catch (error) {
				ctx.ui.notice(`editor failed: ${describeError(error)}`, "error");
			}
		},
	};
}

/** Exported for the help test: the block `/help` produces is one notice. */
export function helpText(lines: string[]): string {
	return indentBlock(lines);
}
