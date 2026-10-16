/** Independent SQLite/store operations, released only by stdin barriers. */
import { Database, constants as sqlite } from "bun:sqlite";
import { mock } from "bun:test";
import type { PathLike } from "node:fs";
import * as fs from "node:fs";

export interface WorkerRequest {
	op: "append" | "clear" | "load" | "hold-insert" | "disabled-no-io";
	prompts?: string[];
	enabled?: boolean;
	maxBytes?: number;
	maxEntries?: number;
	umask?: number;
	/** Force dirty pages into the rollback journal for the SIGKILL recovery case. */
	spill?: boolean;
	/** Pause before this numbered legacy read, inside the import transaction. */
	pauseLegacyRead?: number;
	/** Pause after the migration transaction, immediately before legacy cleanup. */
	pauseLegacyCleanup?: string;
}

export interface WorkerEvent {
	event: "ready" | "started" | "holding" | "import-paused" | "cleanup-paused" | "done" | "error";
	prompts?: string[];
	ioCalls?: number;
	code?: string;
	message?: string;
	elapsedMs?: number;
}

const [file, request] = Bun.argv.slice(2);
const options: WorkerRequest = JSON.parse(request);
// Keep the protocol independent of the child-only filesystem mocks below.
const actual = { ...fs };
let ioCalls = 0;

function announce(event: WorkerEvent): void {
	actual.writeSync(1, `${JSON.stringify(event)}\n`);
}

function barrier(event: "ready" | "holding" | "import-paused" | "cleanup-paused"): void {
	announce({ event });
	const release = Buffer.alloc(1);
	if (actual.readSync(0, release, 0, 1, null) !== 1 || release[0] !== 0x72) {
		throw new Error(`history worker ${event} barrier was not released`);
	}
}

if (options.umask !== undefined) process.umask(options.umask);

if (options.op === "disabled-no-io") {
	const forbidden = () => {
		ioCalls++;
		throw new Error("disabled history attempted storage I/O");
	};
	const intercepted = Object.fromEntries(
		Object.entries(actual).map(([key, value]) => [
			key,
			typeof value === "function" ? forbidden : value,
		]),
	);
	mock.module("node:fs", () => ({ ...intercepted, default: intercepted }));
	mock.module("bun:sqlite", () => ({
		constants: sqlite,
		Database: class {
			constructor() {
				forbidden();
			}
		},
	}));
} else if (options.pauseLegacyCleanup || options.pauseLegacyRead) {
	let cleanupPaused = false;
	let reads = 0;
	mock.module("node:fs", () => ({
		...actual,
		readSync(
			fd: number,
			buffer: Uint8Array,
			offset: number,
			length: number,
			position: number | null,
		) {
			reads++;
			if (reads === options.pauseLegacyRead) barrier("import-paused");
			return actual.readSync(fd, buffer, offset, length, position);
		},
		unlinkSync(path: PathLike) {
			if (!cleanupPaused && String(path) === options.pauseLegacyCleanup) {
				cleanupPaused = true;
				barrier("cleanup-paused");
			}
			actual.unlinkSync(path);
		},
	}));
}

// Static import would bind the store before the child-only module mocks are installed.
const { PromptHistoryStore } = await import("../../src/composer/prompt-history.ts");
// Dependency-module initialization is not a disabled store operation.
ioCalls = 0;
const store = new PromptHistoryStore(file, {
	enabled: options.op === "disabled-no-io" ? false : options.enabled,
	maxBytes: options.maxBytes,
	maxEntries: options.maxEntries,
});
barrier("ready");
announce({ event: "started" });
const started = Date.now();

try {
	if (options.op === "hold-insert") {
		const database = new Database(file);
		try {
			database.exec("PRAGMA busy_timeout = 1500; PRAGMA synchronous = FULL;");
			if (options.spill) database.exec("PRAGMA cache_size = 1; PRAGMA cache_spill = ON");
			database.exec("BEGIN IMMEDIATE");
			const insert = database.query("INSERT INTO prompts (prompt, bytes) VALUES (?, ?)");
			for (const prompt of options.prompts ?? []) {
				insert.run(prompt, Buffer.byteLength(`${JSON.stringify(prompt)}\n`));
			}
			barrier("holding");
			database.exec("COMMIT");
		} finally {
			database.close();
		}
	} else if (options.op === "clear") {
		store.clear();
	} else if (options.op === "load") {
		announce({ event: "done", prompts: store.load() });
		process.exit(0);
	} else if (options.op === "disabled-no-io") {
		const prompts = store.load();
		store.append("must never reach storage");
		announce({ event: "done", prompts, ioCalls });
		process.exit(0);
	} else {
		for (const prompt of options.prompts ?? []) store.append(prompt);
	}
	announce({ event: "done" });
} catch (error) {
	announce({
		event: "error",
		code: (error as NodeJS.ErrnoException).code,
		message: error instanceof Error ? error.message : String(error),
		elapsedMs: Date.now() - started,
	});
}
