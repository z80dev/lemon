#!/usr/bin/env bun
/**
 * Entry point. Owns argument parsing, the runtime check, theme installation and
 * process exit — nothing below this file calls `process.exit`.
 *
 * `--version` and `--help` must work with no TTY and exit 0: the release
 * pipeline smoke-tests the compiled binary that way.
 */

import { loadConfig } from "./config.ts";
import { DEFAULT_WS_URL } from "./protocol/client.ts";
import type { StartupRequest } from "./startup-session.ts";
import { consumeForkHandoff } from "./terminal/fork.ts";

/** Injected by `scripts/build-binary.ts` via Bun's `define`. */
declare const LEMON_TUI_VERSION: string | undefined;

const FALLBACK_VERSION = "2026.8.0";
const MIN_BUN_VERSION = "1.3.14";

export interface CliOptions {
	url: string;
	sessionKey?: string;
	/** `--continue`: attach to this directory's most recently updated TUI session. */
	continueSession: boolean;
	/** `--resume [key]`: attach to `resumeKey`, or open the session switcher without one. */
	resume: boolean;
	resumeKey?: string;
	/** Private one-shot handoff used only by Tern session forks. */
	forkLaunchFile?: string;
	help: boolean;
	version: boolean;
	/** Set when parsing failed; main prints it and exits 2. */
	error?: string;
}

export const USAGE = `lemon-tui — Lemon terminal client

Usage: lemon-tui [options]

Options:
  --ws-url, --url, -u <url>   Control-plane WebSocket URL
                              (default: $LEMON_WS_URL, else ws://127.0.0.1:<port>/ws)
  --session, -s <key>         Session key to attach to (default: fresh local TUI session)
  --continue, -c              Continue this directory's most recently updated TUI
                              session (a new session when none exists)
  --resume, -r [key]          Attach to <key> if it exists, else open the session switcher
  --version, -V               Print the version and exit
  --help, -h                  Print this help and exit

Environment:
  LEMON_WS_URL                Default control-plane URL
  LEMON_CONTROL_PLANE_OPERATOR_TOKEN
                              Operator credential for authenticated control planes
  LEMON_WS_TOKEN              Legacy TUI alias for the operator credential
  LEMON_CONTROL_PLANE_PORT    Port used to build the default URL (default 4040)
  LEMON_TUI_VERSION           Overrides the reported version
  LEMON_TUI_ASCII=1           Force the ASCII glyph set
  LEMON_TUI_ALLOW_NO_TTY=1    Start even without a TTY (pty harnesses)
`;

export function defaultUrl(env: NodeJS.ProcessEnv = process.env): string {
	const explicit = env.LEMON_WS_URL?.trim();
	if (explicit) return explicit;
	const port = env.LEMON_CONTROL_PLANE_PORT?.trim();
	if (port) return `ws://127.0.0.1:${port}/ws`;
	return DEFAULT_WS_URL;
}

export function operatorToken(env: NodeJS.ProcessEnv = process.env): string | undefined {
	return env.LEMON_CONTROL_PLANE_OPERATOR_TOKEN?.trim() || env.LEMON_WS_TOKEN?.trim() || undefined;
}

export function parseArgs(argv: string[], env: NodeJS.ProcessEnv = process.env): CliOptions {
	const options: CliOptions = {
		url: defaultUrl(env),
		help: false,
		version: false,
		continueSession: false,
		resume: false,
	};
	for (let index = 0; index < argv.length; index++) {
		const arg = argv[index];
		const takeValue = (name: string): string | undefined => {
			const next = argv[index + 1];
			if (next === undefined || next.startsWith("-")) {
				options.error = `${name} requires a value`;
				return undefined;
			}
			index += 1;
			return next;
		};
		switch (arg) {
			case "--help":
			case "-h":
				options.help = true;
				break;
			case "--version":
			case "-V":
				options.version = true;
				break;
			case "--ws-url":
			case "--url":
			case "-u": {
				const value = takeValue(arg);
				if (value !== undefined) options.url = value;
				break;
			}
			case "--session":
			case "-s": {
				const value = takeValue(arg);
				if (value !== undefined) options.sessionKey = value;
				break;
			}
			case "--continue":
			case "-c":
				options.continueSession = true;
				break;
			case "--resume":
			case "-r": {
				options.resume = true;
				const next = argv[index + 1];
				if (next !== undefined && !next.startsWith("-")) {
					options.resumeKey = next;
					index += 1;
				}
				break;
			}
			case "--internal-fork-launch": {
				const value = takeValue(arg);
				if (value !== undefined) options.forkLaunchFile = value;
				break;
			}
			default:
				if (arg.startsWith("--ws-url=") || arg.startsWith("--url=")) {
					options.url = arg.slice(arg.indexOf("=") + 1);
				} else if (arg.startsWith("--session=")) {
					options.sessionKey = arg.slice("--session=".length);
				} else if (arg.startsWith("--resume=")) {
					options.resume = true;
					options.resumeKey = arg.slice("--resume=".length) || undefined;
				} else {
					options.error = `unknown argument: ${arg}`;
				}
				break;
		}
	}
	const startupFlags = [
		options.continueSession && "--continue",
		options.sessionKey !== undefined && "--session",
		options.resume && "--resume",
	].filter(Boolean);
	if (startupFlags.length > 1 && !options.error) {
		options.error = `${startupFlags.join(", ")} are mutually exclusive`;
	}
	return options;
}

/** The startup request the shell resolves after connecting, if any. */
export function startupRequest(options: CliOptions): StartupRequest | undefined {
	if (options.continueSession) return { mode: "continue" };
	if (options.resume) return { mode: "resume", key: options.resumeKey };
	return undefined;
}

/** Numeric semver comparison; returns true when `actual` >= `minimum`. */
export function satisfiesVersion(actual: string, minimum: string): boolean {
	const parse = (value: string) =>
		value
			.split(/[.-]/)
			.slice(0, 3)
			.map((part) => Number.parseInt(part, 10) || 0);
	const [aMajor, aMinor, aPatch] = parse(actual);
	const [mMajor, mMinor, mPatch] = parse(minimum);
	if (aMajor !== mMajor) return aMajor > mMajor;
	if (aMinor !== mMinor) return aMinor > mMinor;
	return aPatch >= mPatch;
}

/**
 * Version precedence: env override, then the value baked in at build time, then
 * package.json when running from a checkout, then the compiled-in fallback.
 */
export async function resolveVersion(env: NodeJS.ProcessEnv = process.env): Promise<string> {
	const fromEnv = env.LEMON_TUI_VERSION?.trim();
	if (fromEnv) return fromEnv;
	if (typeof LEMON_TUI_VERSION === "string" && LEMON_TUI_VERSION.length > 0) {
		return LEMON_TUI_VERSION;
	}
	try {
		const file = Bun.file(new URL("../package.json", import.meta.url));
		if (await file.exists()) {
			const pkg = (await file.json()) as { version?: string };
			if (typeof pkg.version === "string" && pkg.version.length > 0) return pkg.version;
		}
	} catch {
		// Compiled binaries have no package.json on disk; fall through.
	}
	return FALLBACK_VERSION;
}

/** Escape hatch for pty-driving harnesses: LEMON_TUI_ALLOW_NO_TTY=1. */
export function hasInteractiveTerminal(env: NodeJS.ProcessEnv = process.env): boolean {
	if (env.LEMON_TUI_ALLOW_NO_TTY === "1") return true;
	return Boolean(process.stdin.isTTY) && Boolean(process.stdout.isTTY);
}

export async function main(argv: string[] = Bun.argv.slice(2)): Promise<number> {
	const options = parseArgs(argv);

	if (options.help) {
		process.stdout.write(USAGE);
		return 0;
	}
	if (options.version) {
		process.stdout.write(`${await resolveVersion()}\n`);
		return 0;
	}
	if (options.error) {
		process.stderr.write(`lemon-tui: ${options.error}\n\n${USAGE}`);
		return 2;
	}
	if (options.forkLaunchFile) {
		try {
			const launch = consumeForkHandoff(options.forkLaunchFile);
			options.url = launch.url;
			options.sessionKey = launch.sessionKey;
			process.chdir(launch.cwd);
			// The daemon launching this pane may have a different environment.
			// Install only the parent's resolved credential, never one from argv.
			delete process.env.LEMON_WS_TOKEN;
			if (launch.operatorToken === undefined) {
				delete process.env.LEMON_CONTROL_PLANE_OPERATOR_TOKEN;
			} else {
				process.env.LEMON_CONTROL_PLANE_OPERATOR_TOKEN = launch.operatorToken;
			}
		} catch {
			process.stderr.write("lemon-tui: could not consume fork launch handoff\n");
			return 2;
		}
	}
	if (!satisfiesVersion(Bun.version, MIN_BUN_VERSION)) {
		process.stderr.write(
			`lemon-tui: requires Bun >= ${MIN_BUN_VERSION} (running ${Bun.version})\n`,
		);
		return 1;
	}
	// Without a TTY the editor would wait forever on input that can never arrive;
	// exit 2 instead of hanging, matching the `lemon` shim's no-TTY contract.
	if (!hasInteractiveTerminal()) {
		process.stderr.write(
			'lemon-tui: requires an interactive terminal — use lemon -p "…" for non-interactive runs, or lemon start to run the runtime\n',
		);
		return 2;
	}

	// Must run before any pi-tui component is constructed: they take their theme
	// by constructor argument and pi-tui ships no defaults. `auto` installs the
	// dark palette now and swaps it if the terminal answers the OSC 11 query
	// with a light background — the answer arrives after the first frame.
	// Keep CLI-only calls out of the native renderer's import graph, and overlap
	// config/version I/O with the interactive module load.
	const [{ AppShell }, { initAppearanceTheme }, config, version] = await Promise.all([
		import("./app.ts"),
		import("./ui/theme/appearance.ts"),
		loadConfig(process.cwd()).catch(() => undefined),
		resolveVersion(),
	]);
	const theme = initAppearanceTheme({ configured: config?.tui?.theme });
	return await new Promise<number>((resolve) => {
		const app = new AppShell({
			url: options.url,
			operatorToken: operatorToken(),
			sessionKey: options.sessionKey,
			startup: startupRequest(options),
			version,
			themePreference: theme.preference,
			notifications: config?.tui?.notifications,
			keybindings: config?.tui?.keys,
			onExit: (code) => resolve(code),
		});
		const shutdown = () => {
			app.stop();
			resolve(0);
		};
		process.once("SIGINT", shutdown);
		process.once("SIGTERM", shutdown);
		void app.start().catch((error) => {
			app.stop();
			process.stderr.write(
				`lemon-tui: could not start the TUI: ${error instanceof Error ? error.message : String(error)}\n`,
			);
			resolve(1);
		});
	});
}

if (import.meta.main) {
	void main().then((code) => process.exit(code));
}
