/**
 * $EDITOR handoff.
 *
 * The editor owns the terminal while it runs, so the TUI has to be stopped
 * first and started again afterwards — in a `finally`, because an editor that
 * crashes must not leave the user in raw mode with no UI. The temp file is
 * removed on the way out whether or not the edit succeeded.
 */

import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

export interface TerminalHost {
	stop(): void;
	start(): void;
}

export interface ExternalEditorOptions {
	/** Suspended around the editor. */
	tui?: TerminalHost;
	/** Overrides `$LEMON_EDITOR` / `$VISUAL` / `$EDITOR`. */
	command?: string;
	/** File extension, so the editor picks a syntax. */
	extension?: string;
	env?: NodeJS.ProcessEnv;
	/** Test seam: defaults to `Bun.spawn` with the terminal inherited. */
	spawn?: (argv: string[], file: string) => Promise<number>;
}

/** The editor to hand off to, or undefined when the environment names none. */
export function resolveEditorCommand(env: NodeJS.ProcessEnv = process.env): string | undefined {
	const candidate = env.LEMON_EDITOR || env.VISUAL || env.EDITOR;
	return candidate?.trim() || undefined;
}

/**
 * Edit `initial` in $EDITOR and return the result.
 *
 * Returns null when the user made no change, so the caller can leave the draft
 * (and its undo history) exactly as it was. Throws only when no editor is
 * configured or the editor could not be started — a non-zero exit is treated as
 * "the user aborted", which is what `:cq` means in vim.
 */
export async function editInExternalEditor(
	initial: string,
	options: ExternalEditorOptions = {},
): Promise<string | null> {
	const env = options.env ?? process.env;
	const command = options.command ?? resolveEditorCommand(env);
	if (!command) {
		throw new Error("no editor configured — set $EDITOR (or $VISUAL)");
	}

	const dir = await mkdtemp(join(tmpdir(), "lemon-tui-"));
	const file = join(dir, `prompt${options.extension ?? ".md"}`);
	await writeFile(file, initial, "utf-8");

	const spawn = options.spawn ?? defaultSpawn;
	// The editor draws over our frame; stop first so the differential renderer
	// does not fight it, and restart in `finally` so a crash still restores us.
	options.tui?.stop();
	let exitCode = 0;
	try {
		exitCode = await spawn(splitEditorCommand(command), file);
	} finally {
		options.tui?.start();
	}

	try {
		if (exitCode !== 0) return null;
		const edited = await readFile(file, "utf-8");
		return edited === initial ? null : edited.replace(/\n+$/, "");
	} finally {
		await rm(dir, { recursive: true, force: true }).catch(() => {});
	}
}

/**
 * Split `$EDITOR` into argv. Editors are commonly configured with flags
 * (`code -w`, `emacsclient -nw`), so a bare split on whitespace is right; there
 * is no shell involved, which is also why no quoting is supported.
 */
export function splitEditorCommand(command: string): string[] {
	return command.split(/\s+/).filter((part) => part.length > 0);
}

async function defaultSpawn(argv: string[], file: string): Promise<number> {
	const proc = Bun.spawn([...argv, file], {
		stdin: "inherit",
		stdout: "inherit",
		stderr: "inherit",
	});
	return await proc.exited;
}
