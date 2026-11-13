/**
 * Activating a link picked in the link browser.
 *
 * Only `http(s)` URLs and local `file:` links are ever opened, and only through
 * the operating system's opener with an argv (no shell), so a link in model
 * output can never run a command or reach another scheme's handler
 * (`javascript:`, `vscode:`, `ssh:` …). Everything else is refused with a reason
 * the browser shows in its footer.
 */

import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

/** What an allowed link opens. */
export type LinkAction =
	| { kind: "web"; url: string }
	| { kind: "file"; path: string; line?: number };

/** Longest link accepted; real URLs are far shorter and the footer must stay readable. */
const MAX_LINK_LENGTH = 8192;

/** The scheme (lowercase, without `:`) of `raw`, for refusal messages. */
function schemeOf(raw: string): string | undefined {
	const colon = raw.indexOf(":");
	if (colon <= 0) return undefined;
	const scheme = raw.slice(0, colon).toLowerCase();
	return /^[a-z][a-z\d+.-]*$/.test(scheme) ? scheme : undefined;
}

/**
 * The action for `raw`, or `undefined` for every link that is not an `http(s)` URL with a host
 * or a `file:` link to this machine (empty or `localhost` host).
 */
export function classifyLink(raw: string): LinkAction | undefined {
	if (!raw || raw.length > MAX_LINK_LENGTH || /[\p{Cc}\s]/u.test(raw)) return undefined;
	// WHATWG parsing repairs malformed input (`https:host`, `https:///host`); a link must already
	// be written as `scheme://host…` (`file://` may have an empty host) to be opened.
	if (!/^(?:https?:\/\/[^/?#]|file:\/\/)/i.test(raw)) return undefined;
	let url: URL;
	try {
		url = new URL(raw);
	} catch {
		return undefined;
	}
	if (url.protocol === "http:" || url.protocol === "https:") {
		return url.hostname ? { kind: "web", url: url.href } : undefined;
	}
	if (url.protocol === "file:") {
		if (url.hostname !== "" && url.hostname !== "localhost") return undefined;
		let path: string;
		try {
			path = fileURLToPath(url);
		} catch {
			return undefined;
		}
		const line = /^#L(\d+)/.exec(url.hash)?.[1];
		const lineNumber = line === undefined ? undefined : Number(line);
		return {
			kind: "file",
			path,
			...(lineNumber !== undefined && Number.isSafeInteger(lineNumber) && lineNumber > 0
				? { line: lineNumber }
				: {}),
		};
	}
	return undefined;
}

/** The OS opener's argv for `target` (an absolute path or an `http(s)` URL). */
export function openerCommand(
	target: string,
	platform: NodeJS.Platform = process.platform,
): string[] {
	if (platform === "darwin") return ["open", target];
	if (platform === "win32") return ["rundll32", "url.dll,FileProtocolHandler", target];
	return ["xdg-open", target];
}

export interface OpenLinkOptions {
	platform?: NodeJS.Platform;
	/** Test seam: whether a local path exists. */
	exists?: (path: string) => boolean;
	/** Test seam: run an argv with the terminal detached; resolves to the exit code. */
	spawn?: (argv: string[]) => Promise<number>;
}

export interface OpenLinkResult {
	ok: boolean;
	/** One line for the browser footer. */
	message: string;
}

async function defaultSpawn(argv: string[]): Promise<number> {
	const proc = Bun.spawn(argv, { stdin: "ignore", stdout: "ignore", stderr: "ignore" });
	return await proc.exited;
}

function shorten(text: string, max = 72): string {
	return text.length <= max ? text : `${text.slice(0, max - 1)}…`;
}

/** Open `raw` if the allowlist permits it; never throws. */
export async function openLink(
	raw: string,
	options: OpenLinkOptions = {},
): Promise<OpenLinkResult> {
	const action = classifyLink(raw);
	if (!action) {
		const scheme = schemeOf(raw);
		return {
			ok: false,
			message: `refused ${scheme ? `${scheme}: ` : ""}link — only http(s) and local file links open`,
		};
	}
	const platform = options.platform ?? process.platform;
	const target = action.kind === "web" ? action.url : action.path;
	if (action.kind === "file" && !(options.exists ?? existsSync)(action.path)) {
		return { ok: false, message: `no such file: ${shorten(action.path)}` };
	}
	const argv = openerCommand(target, platform);
	try {
		const code = await (options.spawn ?? defaultSpawn)(argv);
		if (code !== 0) return { ok: false, message: `${argv[0]} exited with ${code}` };
	} catch {
		return { ok: false, message: `could not run ${argv[0]} to open the link` };
	}
	return { ok: true, message: `opened ${shorten(target)}` };
}
