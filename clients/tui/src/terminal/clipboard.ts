export interface CopyResult {
	/** OSC 52 is unacknowledged: this records a write, not clipboard confirmation. */
	osc52: boolean;
	native?: string;
}

export type ClipboardSpawner = (argv: string[], text: string) => Promise<boolean>;

async function spawnClipboard(argv: string[], text: string): Promise<boolean> {
	const child = Bun.spawn(argv, {
		stdin: new Blob([text]),
		stdout: "ignore",
		stderr: "ignore",
	});
	const timer = setTimeout(() => child.kill("SIGKILL"), 2000);
	try {
		return (await child.exited) === 0;
	} finally {
		clearTimeout(timer);
	}
}

/** No shell or text in argv/diagnostics. Local native copy also covers dropped OSC 52. */
export async function copyText(
	text: string,
	options: {
		write: (sequence: string) => void;
		env?: NodeJS.ProcessEnv;
		platform?: NodeJS.Platform;
		spawn?: ClipboardSpawner;
	},
): Promise<CopyResult> {
	const result: CopyResult = { osc52: false };
	try {
		options.write(`\x1b]52;c;${Buffer.from(text).toString("base64")}\x07`);
		result.osc52 = true;
	} catch {
		// A native clipboard may still be available if the terminal write failed.
	}
	const env = options.env ?? process.env;
	if (env.SSH_TTY || env.SSH_CONNECTION) return result;
	const platform = options.platform ?? process.platform;
	const commands =
		platform === "darwin"
			? [["pbcopy"]]
			: platform === "linux"
				? [["wl-copy"], ["xclip", "-selection", "clipboard"], ["xsel", "--clipboard", "--input"]]
				: [];
	for (const argv of commands) {
		try {
			if (await (options.spawn ?? spawnClipboard)(argv, text)) {
				result.native = argv[0];
				break;
			}
		} catch {
			// Missing binaries and unavailable display servers try the next fixed command.
		}
	}
	return result;
}

export function copyNotice(result: CopyResult): string {
	const paths = [
		...(result.osc52 ? ["sent via OSC 52 (unconfirmed)"] : []),
		...(result.native ? [`copied with ${result.native}`] : []),
	];
	return paths.length > 0
		? `Clipboard: ${paths.join("; ")}.`
		: "Clipboard unavailable: no copy path succeeded.";
}
