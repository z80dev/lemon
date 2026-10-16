/**
 * Private, client-local prompt recall. Every operation opens a short-lived SQLite
 * connection; BEGIN IMMEDIATE orders append, prune, migration and clear across
 * TUIs. No process ever saves a cached copy of history back to disk.
 */
import { Database, constants as sqlite } from "bun:sqlite";
import {
	closeSync,
	constants,
	fchmodSync,
	fstatSync,
	lstatSync,
	mkdirSync,
	openSync,
	readdirSync,
	readSync,
	realpathSync,
	type Stats,
	unlinkSync,
} from "node:fs";
import * as path from "node:path";
import { getConfigDir } from "../config.ts";

export const PROMPT_HISTORY_FILE = "history.sqlite3";
/** Retained JSON-encoded prompt bytes, not SQLite's physical file size. */
export const PROMPT_HISTORY_MAX_BYTES = 256 * 1024;
export const PROMPT_HISTORY_MAX_ENTRIES = 100;

const PRIVATE_FILE = 0o600;
const PRIVATE_DIR = 0o700;
const BUSY_TIMEOUT_MS = 1500;
const LEGACY_FILE = "tui-history.jsonl";
const SIDECARS = ["-journal", "-wal", "-shm"] as const;

export function getPromptHistoryPath(): string {
	return path.join(getConfigDir(), "tui-history", PROMPT_HISTORY_FILE);
}

export interface PromptHistoryLimits {
	maxBytes?: number;
	maxEntries?: number;
	/** No load/append IO; explicit clear still clears saved and legacy history. */
	enabled?: boolean;
}

export class PromptHistoryStore {
	readonly path: string;
	readonly #maxBytes: number;
	readonly #maxEntries: number;
	readonly #enabled: boolean;
	readonly #legacyPath: string;

	constructor(filePath: string = getPromptHistoryPath(), limits: PromptHistoryLimits = {}) {
		this.path = path.resolve(filePath);
		this.#maxBytes = limits.maxBytes ?? PROMPT_HISTORY_MAX_BYTES;
		this.#maxEntries = limits.maxEntries ?? PROMPT_HISTORY_MAX_ENTRIES;
		this.#enabled = limits.enabled ?? true;
		this.#legacyPath = path.join(
			path.basename(path.dirname(this.path)) === "tui-history"
				? path.dirname(path.dirname(this.path))
				: path.dirname(this.path),
			LEGACY_FILE,
		);
	}

	load(): string[] {
		if (!this.#enabled) return [];
		return this.#withDatabase("load", (db) => {
			this.#migrate(db);
			this.#prune(db);
			return db
				.query<{ prompt: string }, []>("SELECT prompt FROM prompts ORDER BY id")
				.all()
				.map((row) => row.prompt);
		});
	}

	/** Called for submitted prompts only, never for edits or discarded drafts. */
	append(prompt: string): void {
		if (!this.#enabled || prompt.trim().length === 0) return;
		const bytes = encodedBytes(prompt);
		// Oversized prompts remain available in the editor's in-memory recall ring.
		if (bytes > this.#maxBytes || this.#maxEntries === 0) return;
		this.#withDatabase("save", (db) => {
			this.#migrate(db);
			this.#insert(db, prompt, bytes);
			this.#prune(db);
		});
	}

	/** Keep the DB inode: unlinking a live SQLite database splits writers. */
	clear(): void {
		this.#withDatabase("clear", (db) => {
			// Commit the import fence together with deletion, BEFORE source cleanup.
			// A crash or cleanup failure can never cause old prompts to be reimported.
			db.run("INSERT OR REPLACE INTO metadata(key, value) VALUES ('legacy_migrated', '1')");
			db.run("DELETE FROM prompts");
		});
	}

	#withDatabase<T>(operation: string, run: (db: Database) => T): T {
		let db: Database | undefined;
		try {
			secureDirectory(path.dirname(this.path));
			secureFile(this.path, true);
			for (const suffix of SIDECARS) secureFile(`${this.path}${suffix}`, false);
			// SQLite NOFOLLOW checks every component, including macOS's trusted
			// /var alias. Resolve only AFTER rejecting user-controlled links above.
			db = new Database(
				realpathSync(this.path),
				sqlite.SQLITE_OPEN_READWRITE | sqlite.SQLITE_OPEN_NOFOLLOW,
			);
			db.exec(`PRAGMA busy_timeout = ${BUSY_TIMEOUT_MS}`);
			// DELETE journals have no ever-growing WAL. SQLite derives journal mode
			// bits from the precreated 0600 database, including under umask 000.
			db.exec(
				"PRAGMA journal_mode = DELETE; PRAGMA synchronous = FULL; PRAGMA secure_delete = ON; PRAGMA temp_store = MEMORY; PRAGMA journal_size_limit = 0; PRAGMA auto_vacuum = FULL",
			);
			// Allow SQLite's page/index overhead and one pending append before prune.
			// This bounds page allocation, NOT a proven cap on all filesystem bytes.
			const pages = Math.max(128, Math.ceil(this.#maxBytes / 4096) * 4 + 128);
			db.exec(`PRAGMA max_page_count = ${pages}`);
			const result = db
				.transaction(() => {
					db!.exec(
						"CREATE TABLE IF NOT EXISTS prompts (id INTEGER PRIMARY KEY, prompt TEXT NOT NULL, bytes INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
					);
					return run(db!);
				})
				.immediate();
			db.close();
			db = undefined;
			// A committed migration marker makes this cleanup retryable without
			// repeating the import. Clear must report a retained source as a failure.
			this.#removeLegacy();
			return result;
		} catch (error) {
			throw historyError(operation, error);
		} finally {
			db?.close();
		}
	}

	#insert(db: Database, prompt: string, bytes = encodedBytes(prompt)): void {
		if (bytes > this.#maxBytes || this.#maxEntries === 0) return;
		const last = db
			.query<{ prompt: string }, []>("SELECT prompt FROM prompts ORDER BY id DESC LIMIT 1")
			.get();
		if (last?.prompt !== prompt) {
			db.run("INSERT INTO prompts(prompt, bytes) VALUES (?, ?)", [prompt, bytes]);
		}
	}

	#prune(db: Database): void {
		db.run(
			`DELETE FROM prompts WHERE id IN (
			SELECT id FROM (
				SELECT id, row_number() OVER (ORDER BY id DESC) AS position,
					sum(bytes) OVER (ORDER BY id DESC ROWS UNBOUNDED PRECEDING) AS retained_bytes
				FROM prompts
			) WHERE position > ? OR retained_bytes > ?
		)`,
			[this.#maxEntries, this.#maxBytes],
		);
	}

	#migrate(db: Database): void {
		if (db.query("SELECT value FROM metadata WHERE key = 'legacy_migrated'").get()) return;
		for (const file of this.#legacySources()) {
			for (const prompt of readLegacyTail(file, this.#maxBytes)) {
				this.#insert(db, prompt);
				this.#prune(db);
			}
		}
		db.run("INSERT INTO metadata(key, value) VALUES ('legacy_migrated', '1')");
	}

	/** Import-only compatibility: no old storage writer/rotation protocol remains. */
	#legacySources(): string[] {
		const dir = path.dirname(this.#legacyPath);
		const base = path.basename(this.#legacyPath);
		let names: string[];
		try {
			names = readdirSync(dir);
		} catch (error) {
			if (isAbsent(error)) return [];
			throw error;
		}
		const numbered: string[] = [];
		const stamped: string[] = [];
		for (const name of names) {
			if (!name.startsWith(`${base}.`)) continue;
			const suffix = name.slice(base.length + 1);
			if (/^\d+$/.test(suffix)) numbered.push(name);
			else if (/^\d{13,16}-[1-9]\d*-[a-f0-9]{16}$/.test(suffix)) stamped.push(name);
		}
		// Old numeric backups put the oldest at the highest number. Timestamps
		// supply a deterministic import order only, not eviction or a chronology
		// guarantee for old concurrently-written files. The current source is last.
		numbered.sort((a, b) => Number(b.slice(base.length + 1)) - Number(a.slice(base.length + 1)));
		stamped.sort();
		return [...numbered, ...stamped, ...(names.includes(base) ? [base] : [])].map((name) =>
			path.join(dir, name),
		);
	}

	#removeLegacy(): void {
		let failure: unknown;
		for (const file of this.#legacySources()) {
			try {
				// Validate first: never follow a source symlink or delete an unrelated
				// directory. A failure is visible even though the import fence is set.
				secureFile(file, false);
				unlinkSync(file);
			} catch (error) {
				if (!isAbsent(error)) failure ??= error;
			}
		}
		if (failure !== undefined) throw failure;
	}
}

function encodedBytes(prompt: string): number {
	return Buffer.byteLength(`${JSON.stringify(prompt)}\n`);
}

function isAbsent(error: unknown): boolean {
	return (error as NodeJS.ErrnoException).code === "ENOENT";
}

function unsafe(message: string): never {
	throw Object.assign(new Error(message), { code: "EACCES" });
}

/** Validate each user-owned path component, not just the final directory. */
function secureDirectory(directory: string): void {
	const parent = path.dirname(directory);
	if (parent !== directory) {
		let stat: Stats;
		try {
			stat = lstatSync(parent);
		} catch (error) {
			if (!isAbsent(error)) throw error;
			secureDirectory(parent);
			stat = lstatSync(parent);
		}
		checkAncestors(parent);
		if (!stat.isDirectory()) unsafe("history parent is not a directory");
	}
	try {
		mkdirSync(directory, { mode: PRIVATE_DIR });
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
	}
	const stat = lstatSync(directory);
	if (
		!stat.isDirectory() ||
		stat.uid !== process.getuid?.() ||
		(stat.mode & 0o777) !== PRIVATE_DIR
	) {
		unsafe(
			"history directory must be a real, current-user-owned mode-0700 directory (not a symlink)",
		);
	}
}

function checkAncestors(directory: string): void {
	const stat = lstatSync(directory);
	// macOS has root-owned /var and /tmp symlinks. They are trusted OS path
	// aliases, not user-controlled history directories. Never allow a symlink
	// at HOME, .lemon or the storage directory itself.
	if (stat.isSymbolicLink()) {
		if (stat.uid !== 0 || (directory !== "/var" && directory !== "/tmp")) {
			unsafe("history parent must not be a symlink");
		}
	} else if (!stat.isDirectory() || (stat.uid !== 0 && stat.uid !== process.getuid?.())) {
		unsafe("history parent must be an owned directory");
	} else if ((stat.mode & 0o022) !== 0 && (stat.mode & 0o1000) === 0) {
		unsafe("history parent must not be writable by other users");
	}
	const parent = path.dirname(directory);
	if (parent !== directory) checkAncestors(parent);
}

/** NOFOLLOW plus owner/type/link-count checks before SQLite sees any pathname. */
function secureFile(file: string, create: boolean): void {
	let fd: number;
	try {
		fd = openSync(
			file,
			constants.O_RDWR |
				constants.O_NONBLOCK |
				constants.O_NOFOLLOW |
				(create ? constants.O_CREAT : 0),
			PRIVATE_FILE,
		);
	} catch (error) {
		if (!create && isAbsent(error)) return;
		throw error;
	}
	try {
		const stat = fstatSync(fd);
		if (!stat.isFile() || stat.uid !== process.getuid?.() || stat.nlink !== 1) {
			unsafe(
				"history database, sidecars and legacy sources must be owned regular files with no hard links",
			);
		}
		if ((stat.mode & 0o777) !== PRIVATE_FILE) fchmodSync(fd, PRIVATE_FILE);
	} finally {
		closeSync(fd);
	}
}

function readLegacyTail(file: string, maxBytes: number): string[] {
	secureFile(file, false);
	let fd: number;
	try {
		fd = openSync(file, constants.O_RDONLY | constants.O_NONBLOCK | constants.O_NOFOLLOW);
	} catch (error) {
		if (isAbsent(error)) return [];
		throw error;
	}
	try {
		const stat = fstatSync(fd);
		const length = Math.min(stat.size, maxBytes + 1);
		const start = stat.size - length;
		const buffer = Buffer.alloc(length);
		let count = 0;
		while (count < length) {
			const n = readSync(fd, buffer, count, length - count, start + count);
			if (n === 0) break;
			count += n;
		}
		let text = buffer.toString("utf8", 0, count);
		if (start > 0) {
			const newline = text.indexOf("\n");
			text = newline < 0 ? "" : text.slice(newline + 1);
		}
		const prompts: string[] = [];
		for (const line of text.split("\n")) {
			try {
				const value: unknown = JSON.parse(line);
				if (typeof value === "string" && value.trim().length > 0) prompts.push(value);
			} catch {
				// Damaged legacy lines cost that prompt only.
			}
		}
		return prompts;
	} finally {
		closeSync(fd);
	}
}

function historyError(operation: string, error: unknown): Error {
	const code = (error as NodeJS.ErrnoException).code;
	const detail = error instanceof Error ? error.message : String(error);
	const busy =
		code === "SQLITE_BUSY" ||
		code === "SQLITE_LOCKED" ||
		/database is (?:locked|busy)/i.test(detail);
	return Object.assign(
		new Error(
			busy
				? `Cannot ${operation} prompt history: SQLite is busy after at most ${BUSY_TIMEOUT_MS} ms; finish the other TUI's history operation and try again.`
				: `Cannot ${operation} prompt history (${code ?? "SQLite/filesystem error"}: ${detail}). Check history directory ownership, mode 0700, file permissions and available disk space; [tui] prompt_history = false disables persistence.`,
			{ cause: error },
		),
		{ code },
	);
}
