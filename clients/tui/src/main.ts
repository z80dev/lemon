#!/usr/bin/env bun
/**
 * Entry point. Owns argument parsing, the runtime check, theme installation and
 * process exit — nothing below this file calls `process.exit`.
 *
 * `--version` and `--help` must work with no TTY and exit 0: the release
 * pipeline smoke-tests the compiled binary that way.
 */

import { AppShell } from "./app.ts";
import { DEFAULT_WS_URL } from "./protocol/client.ts";
import { initTheme } from "./ui/theme/theme.ts";

/** Injected by `scripts/build-binary.ts` via Bun's `define`. */
declare const LEMON_TUI_VERSION: string | undefined;

const FALLBACK_VERSION = "2026.8.0";
const MIN_BUN_VERSION = "1.3.14";

export interface CliOptions {
	url: string;
	sessionKey?: string;
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
  --session, -s <key>         Session key to attach to (default: tui-<timestamp>)
  --version, -V               Print the version and exit
  --help, -h                  Print this help and exit

Environment:
  LEMON_WS_URL                Default control-plane URL
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

export function parseArgs(argv: string[], env: NodeJS.ProcessEnv = process.env): CliOptions {
	const options: CliOptions = { url: defaultUrl(env), help: false, version: false };
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
			default:
				if (arg.startsWith("--ws-url=") || arg.startsWith("--url=")) {
					options.url = arg.slice(arg.indexOf("=") + 1);
				} else if (arg.startsWith("--session=")) {
					options.sessionKey = arg.slice("--session=".length);
				} else {
					options.error = `unknown argument: ${arg}`;
				}
				break;
		}
	}
	return options;
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
	if (!satisfiesVersion(Bun.version, MIN_BUN_VERSION)) {
		process.stderr.write(
			`lemon-tui: requires Bun >= ${MIN_BUN_VERSION} (running ${Bun.version})\n`,
		);
		return 1;
	}
	// Without a TTY the editor would wait forever on input that can never arrive;
	// exit 2 instead of hanging, matching the `lemon` shim's no-TTY contract.
	if (!hasInteractiveTerminal()) {
		process.stderr.write("lemon-tui: requires an interactive terminal (no TTY detected)\n");
		return 2;
	}

	// Must run before any pi-tui component is constructed: they take their theme
	// by constructor argument and pi-tui ships no defaults.
	initTheme();

	const version = await resolveVersion();
	return await new Promise<number>((resolve) => {
		const app = new AppShell({
			url: options.url,
			sessionKey: options.sessionKey,
			version,
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
				`lemon-tui: ${error instanceof Error ? error.message : String(error)}\n`,
			);
			resolve(1);
		});
	});
}

if (import.meta.main) {
	process.exit(await main());
}
