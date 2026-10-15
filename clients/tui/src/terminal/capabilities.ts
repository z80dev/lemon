import { shouldEnableHyperlinksByDefault } from "@oh-my-pi/pi-tui/terminal-capabilities";
import { type NotificationMode, resolveNotifications } from "../config.ts";

export interface TerminalCapabilities {
	enabled: boolean;
	tern: boolean;
	hyperlinks: boolean;
	notifications: "osc9" | "osc777" | "bell" | false;
}

/** Environment identity selects side channels; keyboard support is probed by pi-tui. */
export function detectTerminalCapabilities(
	env: NodeJS.ProcessEnv = process.env,
	isTTY = Boolean(process.stdout.isTTY),
	notificationMode: NotificationMode = resolveNotifications(undefined, env),
): TerminalCapabilities {
	const program = env.TERM_PROGRAM?.toLowerCase() ?? "";
	const tern = Boolean(env.TERN_PANE) || program === "tern" || program === "stencil";
	const enabled = isTTY && env.TERM !== "dumb" && env.LEMON_TUI_TERMINAL_INTEGRATION !== "0";
	const osc =
		tern || ["iterm.app", "ghostty", "wezterm", "warpterminal"].includes(program)
			? "osc9"
			: ["foot", "rxvt-unicode"].includes(program)
				? "osc777"
				: undefined;
	return {
		enabled,
		tern,
		// Reuse upstream's explicit opt-outs and multiplexer policy, including
		// panes that export TERN_PANE without a TERM_PROGRAM identity.
		hyperlinks:
			enabled &&
			(tern ? shouldEnableHyperlinksByDefault(env, "kitty") : shouldEnableHyperlinksByDefault(env)),
		notifications:
			!enabled || notificationMode === "off"
				? false
				: notificationMode === "bell"
					? "bell"
					: (osc ?? (notificationMode === "osc" ? "osc777" : "bell")),
	};
}

/** No protocol delimiters or control characters from session/tool metadata. */
export function oscText(text: string): string {
	return text.replace(/\p{Cc}/gu, "").slice(0, 240);
}
