/**
 * Which palette the client wears, and who decides.
 *
 * Precedence, highest first:
 *   1. `LEMON_TUI_THEME` — an explicit env override always wins;
 *   2. the config file's `agent.theme` (what `/theme` persists);
 *   3. the terminal's own background, reported over OSC 11 by pi-tui's
 *      {@link Terminal.appearance} / `onAppearanceChange`;
 *   4. dark.
 *
 * Levels 1 and 2 may name `auto`, which means "skip to 3" rather than "pick
 * dark": that is the difference between a user who wants dark and a user who
 * wants whatever their terminal is.
 *
 * The OSC 11 answer usually arrives a few frames *after* startup (it is a query
 * the terminal replies to), so `auto` installs a provisional palette
 * immediately and {@link AppearanceController} swaps it when the report lands.
 * That swap goes through {@link Theme.apply}, so components which captured
 * theme adapters at construction recolor with everything else.
 */

import type { Terminal, TerminalAppearance } from "@oh-my-pi/pi-tui/terminal";
import {
	getTheme,
	initTheme,
	paletteFor,
	peekTheme,
	type Theme,
	type ThemeOptions,
	themeNameFor,
} from "./theme.ts";
import { invalidateThemeAdapters } from "./tui-adapters.ts";

/** What the user asked for. `auto` defers to the terminal. */
export type ThemePreference = "auto" | "dark" | "light";

/** Which rule settled the appearance — reported by `/theme` with no argument. */
export type AppearanceSource = "env" | "config" | "terminal" | "default";

export interface AppearanceResolution {
	preference: ThemePreference;
	appearance: TerminalAppearance;
	source: AppearanceSource;
}

export const THEME_ENV_VAR = "LEMON_TUI_THEME";

/**
 * Read a preference word. Accepts the palette names `/theme` persists as well
 * as the bare words, so a config written by any version keeps resolving.
 */
export function normalizePreference(value: string | undefined | null): ThemePreference | undefined {
	const text = value?.trim().toLowerCase();
	if (!text) return undefined;
	if (text === "auto" || text === "system") return "auto";
	if (text === "light" || text === "lemon-light") return "light";
	if (text === "dark" || text === "lemon-dark") return "dark";
	return undefined;
}

export interface ResolveAppearanceOptions {
	env?: NodeJS.ProcessEnv;
	/** `agent.theme` from the config file, if any. */
	configured?: string;
	/** What the terminal reported over OSC 11, when it already has. */
	terminalAppearance?: TerminalAppearance | undefined;
}

/** The preference in force, and where it came from. */
export function resolvePreference(options: ResolveAppearanceOptions = {}): {
	preference: ThemePreference;
	source: "env" | "config" | "default";
} {
	const env = options.env ?? process.env;
	const fromEnv = normalizePreference(env[THEME_ENV_VAR]);
	if (fromEnv) return { preference: fromEnv, source: "env" };
	const fromConfig = normalizePreference(options.configured);
	if (fromConfig) return { preference: fromConfig, source: "config" };
	return { preference: "auto", source: "default" };
}

/** Resolve preference *and* the appearance it currently implies. */
export function resolveAppearance(options: ResolveAppearanceOptions = {}): AppearanceResolution {
	const { preference, source } = resolvePreference(options);
	if (preference !== "auto") return { preference, appearance: preference, source };
	const reported = options.terminalAppearance;
	if (reported) return { preference, appearance: reported, source: "terminal" };
	return { preference, appearance: "dark", source: "default" };
}

/**
 * Install `appearance` process-wide. The first call builds the theme; later
 * calls mutate that same instance, so every style function already handed to a
 * component keeps working and starts painting in the new palette.
 */
export function installAppearance(
	appearance: TerminalAppearance,
	options: Omit<ThemeOptions, "appearance" | "palette" | "name"> = {},
): Theme {
	const existing = peekTheme();
	const spec = {
		name: themeNameFor(appearance),
		appearance,
		palette: paletteFor(appearance),
	};
	const theme = existing ? existing.apply(spec) : initTheme({ ...options, ...spec });
	invalidateThemeAdapters();
	return theme;
}

/**
 * Startup bootstrap: resolve and install in one step. Returns what it decided
 * so the caller can hand the preference to {@link AppearanceController}.
 */
export function initAppearanceTheme(
	options: ResolveAppearanceOptions & Omit<ThemeOptions, "appearance" | "palette" | "name"> = {},
): AppearanceResolution {
	const { env, configured, terminalAppearance, ...themeOptions } = options;
	const resolution = resolveAppearance({ env, configured, terminalAppearance });
	installAppearance(resolution.appearance, themeOptions);
	return resolution;
}

export interface AppearanceControllerOptions {
	/** Where OSC 11 reports come from. Optional: tests pass none. */
	terminal?: Pick<Terminal, "appearance" | "onAppearanceChange"> | undefined;
	preference?: ThemePreference;
	/** Called after the installed palette actually changed. */
	onChange?: (appearance: TerminalAppearance) => void;
}

/**
 * Keeps the installed palette in step with the preference.
 *
 * While the preference is `auto` the terminal drives: pi-tui replays an
 * already-detected appearance to late subscribers, so subscribing after startup
 * still sees the first report. An explicit `dark`/`light` pins the palette and
 * the terminal's reports are recorded but not acted on — flipping the terminal
 * to light must not override someone who asked for dark.
 */
export class AppearanceController {
	#terminal: AppearanceControllerOptions["terminal"];
	#onChange: ((appearance: TerminalAppearance) => void) | undefined;
	#preference: ThemePreference;
	#appearance: TerminalAppearance;
	/** The last thing the terminal told us, whatever the preference is. */
	#reported: TerminalAppearance | undefined;
	#subscribed = false;

	constructor(options: AppearanceControllerOptions = {}) {
		this.#terminal = options.terminal;
		this.#onChange = options.onChange;
		this.#preference = options.preference ?? "auto";
		this.#reported = options.terminal?.appearance;
		this.#appearance = getTheme().appearance;
	}

	get preference(): ThemePreference {
		return this.#preference;
	}

	get appearance(): TerminalAppearance {
		return this.#appearance;
	}

	/** What the terminal reported, if it ever has. */
	get reported(): TerminalAppearance | undefined {
		return this.#reported;
	}

	/** Subscribe to the terminal and settle the palette for the preference. */
	start(): void {
		this.#subscribe();
		this.#settle();
	}

	/** `/theme <light|dark|auto>`. Returns the appearance now installed. */
	setPreference(preference: ThemePreference): TerminalAppearance {
		this.#preference = preference;
		if (preference === "auto") this.#subscribe();
		this.#settle();
		return this.#appearance;
	}

	/** The appearance a preference implies right now. */
	resolve(preference: ThemePreference = this.#preference): TerminalAppearance {
		if (preference !== "auto") return preference;
		return this.#reported ?? "dark";
	}

	/** Feed a report in directly (the terminal callback, and tests). */
	report(appearance: TerminalAppearance): void {
		this.#reported = appearance;
		if (this.#preference === "auto") this.#settle();
	}

	#subscribe(): void {
		if (this.#subscribed || !this.#terminal) return;
		this.#subscribed = true;
		// pi-tui replays an appearance detected before this call, so a late
		// subscriber never misses the startup report.
		this.#terminal.onAppearanceChange((appearance) => this.report(appearance));
	}

	/** Install whatever the preference now implies, if it moved. */
	#settle(): void {
		const next = this.resolve();
		const installed = peekTheme();
		if (next === this.#appearance && installed?.appearance === next) return;
		this.#appearance = next;
		installAppearance(next);
		this.#onChange?.(next);
	}
}
