import { Database } from "bun:sqlite";
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import {
	chmodSync,
	existsSync,
	linkSync,
	mkdirSync,
	mkdtempSync,
	readdirSync,
	readFileSync,
	rmSync,
	statSync,
	symlinkSync,
	utimesSync,
	writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import {
	getPromptHistoryPath,
	PROMPT_HISTORY_FILE,
	PROMPT_HISTORY_MAX_BYTES,
	PROMPT_HISTORY_MAX_ENTRIES,
	PromptHistoryStore,
} from "../../src/composer/prompt-history.ts";
import type { WorkerEvent, WorkerRequest } from "./prompt-history-worker.ts";

let home: string;
let previousHome: string | undefined;
const children = new Set<Bun.Subprocess>();
const workerPath = join(import.meta.dir, "prompt-history-worker.ts");

// These are watchdogs for real subprocess pipes, not delays used to order operations.
// Fake timers cannot bound a crashed independent process; stdin/stdout order every race.
async function bounded<T>(promise: Promise<T>, label: string, timeout = 5000): Promise<T> {
	let cancelTimeout = () => {};
	try {
		return await Promise.race([
			promise,
			new Promise<never>((_resolve, reject) => {
				const timer = setTimeout(
					() => reject(new Error(`Timed out waiting for ${label}`)),
					timeout,
				);
				cancelTimeout = () => clearTimeout(timer);
			}),
		]);
	} finally {
		cancelTimeout();
	}
}

beforeEach(() => {
	previousHome = process.env.HOME;
	home = mkdtempSync(join(tmpdir(), "lemon-prompt-history-"));
	process.env.HOME = home;
});

afterEach(async () => {
	try {
		await bounded(
			Promise.all(
				[...children].map(async (child) => {
					if (child.exitCode === null) child.kill("SIGKILL");
					await child.exited;
				}),
			),
			"history worker cleanup",
		);
	} finally {
		children.clear();
		if (previousHome === undefined) delete process.env.HOME;
		else process.env.HOME = previousHome;
		rmSync(home, { recursive: true, force: true });
	}
});

const mode = (path: string) => statSync(path).mode & 0o777;
const databasePath = () => join(home, "private", "history.sqlite3");
const encodedBytes = (prompt: string) => Buffer.byteLength(`${JSON.stringify(prompt)}\n`);
const encode = (prompts: readonly string[]) =>
	prompts.map((prompt) => `${JSON.stringify(prompt)}\n`).join("");

interface PromptRow {
	id: number;
	prompt: string;
	bytes: number;
}

function inspect<T>(file: string, read: (database: Database) => T): T {
	const database = new Database(file, { readonly: true });
	try {
		return read(database);
	} finally {
		database.close();
	}
}

function rows(file: string): PromptRow[] {
	return inspect(
		file,
		(database) =>
			database.query("SELECT id, prompt, bytes FROM prompts ORDER BY id").all() as PromptRow[],
	);
}

function migrationMarker(file: string): { value: string } | null {
	return inspect(
		file,
		(database) =>
			database.query("SELECT value FROM metadata WHERE key = 'legacy_migrated'").get() as {
				value: string;
			} | null,
	);
}

function pageState(file: string) {
	return inspect(file, (database) => {
		const number = (pragma: string) =>
			Object.values(database.query(`PRAGMA ${pragma}`).get() as Record<string, number>)[0];
		return {
			pages: number("page_count"),
			pageSize: number("page_size"),
			freePages: number("freelist_count"),
			autoVacuum: number("auto_vacuum"),
		};
	});
}

function expectRows(file: string, prompts: readonly string[]): void {
	const actual = rows(file);
	expect(actual.map((row) => row.prompt)).toEqual([...prompts]);
	expect(actual.map((row) => row.bytes)).toEqual(prompts.map(encodedBytes));
	for (let index = 1; index < actual.length; index++) {
		expect(actual[index].id).toBeGreaterThan(actual[index - 1].id);
	}
}

function expectDeleteJournal(file: string): void {
	expect(inspect(file, (database) => database.query("PRAGMA journal_mode").get())).toEqual({
		journal_mode: "delete",
	});
	for (const suffix of ["-journal", "-wal", "-shm"]) {
		expect(existsSync(`${file}${suffix}`)).toBe(false);
	}
	expect(readdirSync(dirname(file))).toEqual([basename(file)]);
}

function failure(operation: () => unknown): Error & { code?: string } {
	try {
		operation();
	} catch (error) {
		expect(error).toBeInstanceOf(Error);
		return error as Error & { code?: string };
	}
	throw new Error("Expected prompt history storage to reject the operation");
}

function spawnWorker(file: string, request: WorkerRequest) {
	const process = Bun.spawn(
		[globalThis.process.execPath, workerPath, file, JSON.stringify(request)],
		{
			stdin: "pipe",
			stdout: "pipe",
			stderr: "pipe",
			env: { ...globalThis.process.env, HOME: home },
		},
	);
	children.add(process);
	const reader = process.stdout.getReader();
	const stderr = new Response(process.stderr).text();
	const decoder = new TextDecoder();
	let buffered = "";

	async function next(): Promise<WorkerEvent> {
		return bounded(
			(async () => {
				while (!buffered.includes("\n")) {
					const chunk = await reader.read();
					if (chunk.done) throw new Error("History worker exited before its next barrier");
					buffered += decoder.decode(chunk.value, { stream: true });
				}
				const newline = buffered.indexOf("\n");
				const event: WorkerEvent = JSON.parse(buffered.slice(0, newline));
				buffered = buffered.slice(newline + 1);
				return event;
			})(),
			"history worker event",
		);
	}

	return {
		async event(expected: WorkerEvent["event"]): Promise<WorkerEvent> {
			const event = await next();
			expect(event.event).toBe(expected);
			return event;
		},
		async release(): Promise<void> {
			process.stdin.write("r");
			await bounded(Promise.resolve(process.stdin.flush()), "history worker stdin");
		},
		async finish(): Promise<WorkerEvent> {
			const event = await next();
			expect(["done", "error"]).toContain(event.event);
			process.stdin.end();
			expect(await bounded(process.exited, "history worker exit")).toBe(0);
			expect(await bounded(stderr, "history worker stderr")).toBe("");
			children.delete(process);
			reader.releaseLock();
			return event;
		},
		async kill(): Promise<void> {
			process.kill("SIGKILL");
			await bounded(process.exited, "killed history worker exit");
			await bounded(stderr, "killed history worker stderr");
			children.delete(process);
			reader.releaseLock();
		},
	};
}

async function startWorker(file: string, request: WorkerRequest) {
	const worker = spawnWorker(file, request);
	await worker.event("ready");
	await worker.release();
	await worker.event("started");
	return worker;
}

async function runWorker(file: string, request: WorkerRequest): Promise<WorkerEvent> {
	return (await startWorker(file, request)).finish();
}

function legacySource(suffix?: string | number): string {
	const base = join(home, ".lemon", "tui-history.jsonl");
	return suffix === undefined ? base : `${base}.${suffix}`;
}

function writeLegacySource(
	suffix: string | number | undefined,
	prompts: readonly string[],
): string {
	const path = legacySource(suffix);
	mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
	writeFileSync(path, encode(prompts), { mode: 0o600 });
	return path;
}

describe("PromptHistoryStore SQLite retention", () => {
	test("uses the dedicated private SQLite path and unchanged logical defaults", () => {
		expect(getPromptHistoryPath()).toBe(join(home, ".lemon", "tui-history", "history.sqlite3"));
		expect(getPromptHistoryPath()).toBe(join(home, ".lemon", "tui-history", PROMPT_HISTORY_FILE));
		expect(PROMPT_HISTORY_MAX_BYTES).toBe(256 * 1024);
		expect(PROMPT_HISTORY_MAX_ENTRIES).toBe(100);
		const store = new PromptHistoryStore();
		store.append("first");
		expect(store.load()).toEqual(["first"]);
		expect(readFileSync(getPromptHistoryPath()).subarray(0, 16).toString()).toBe(
			"SQLite format 3\0",
		);
		expectRows(getPromptHistoryPath(), ["first"]);
		expectDeleteJournal(getPromptHistoryPath());
	});

	test("round-trips multiline, JSON-looking, escaped, and Unicode text oldest first", () => {
		const file = databasePath();
		const store = new PromptHistoryStore(file);
		const prompts = ["line one\nline two", '{"a": 1}', 'quote " and \\ slash\t', "λ🌱é\u2028"];
		for (const prompt of prompts) store.append(prompt);
		expect(store.load()).toEqual(prompts);
		expectRows(file, prompts);
	});

	test("prunes oldest rows in each append transaction to the entry cap", () => {
		const file = databasePath();
		const store = new PromptHistoryStore(file, { maxEntries: 3 });
		const prompts = Array.from({ length: 12 }, (_, index) => `prompt-${index}`);
		for (let index = 0; index < prompts.length; index++) {
			store.append(prompts[index]);
			const expected = prompts.slice(Math.max(0, index - 2), index + 1);
			expectRows(file, expected);
			expect(store.load()).toEqual(expected);
		}
	});

	test("counts UTF-8 JSON framing, accepts the exact byte bound, and skips oversized records", () => {
		const file = databasePath();
		const store = new PromptHistoryStore(file, { maxBytes: 46, maxEntries: 3 });
		const prompts = ["λ".repeat(10), "🌱".repeat(5), "é".repeat(10)];
		for (const prompt of prompts) store.append(prompt);
		expect(store.load()).toEqual(prompts.slice(-2));
		expectRows(file, prompts.slice(-2));
		expect(rows(file).reduce((sum, row) => sum + row.bytes, 0)).toBe(46);
		const before = rows(file);
		store.append("🌱".repeat(20));
		expect(rows(file)).toEqual(before);
		const exact = "🌱".repeat(10);
		const exactStore = new PromptHistoryStore(file, { maxBytes: encodedBytes(exact) });
		exactStore.append(exact);
		expectRows(file, [exact]);
		exactStore.append(`${exact}x`);
		expectRows(file, [exact]);
	});

	test("enforces byte and count limits together without retaining pruned rows", () => {
		const file = databasePath();
		const maxBytes = 70;
		const maxEntries = 3;
		const store = new PromptHistoryStore(file, { maxBytes, maxEntries });
		const expected: string[] = [];
		for (const prompt of ["a", "b", "c", "d", "λ".repeat(20), "🌱".repeat(8), "e", "f"]) {
			expected.push(prompt);
			while (
				expected.length > maxEntries ||
				expected.reduce((sum, value) => sum + encodedBytes(value), 0) > maxBytes
			) {
				expected.shift();
			}
			store.append(prompt);
			expectRows(file, expected);
			expect(store.load()).toEqual(expected);
		}
	});

	test("deduplicates against the last committed row, not a store-local last prompt", () => {
		const file = databasePath();
		const a = new PromptHistoryStore(file);
		const b = new PromptHistoryStore(file);
		a.append("same");
		b.append("same");
		a.append("middle");
		b.append("same");
		a.append("same");
		expectRows(file, ["same", "middle", "same"]);
		expect(a.load()).toEqual(["same", "middle", "same"]);
	});

	test("the same store can append the same prompt after another store clears", () => {
		const file = databasePath();
		const a = new PromptHistoryStore(file);
		const b = new PromptHistoryStore(file);
		a.append("same");
		const inode = statSync(file).ino;
		b.clear();
		expect(statSync(file).ino).toBe(inode);
		expectRows(file, []);
		a.append("same");
		expect(a.load()).toEqual(["same"]);
		expectRows(file, ["same"]);
		b.clear();
		b.clear();
		expect(existsSync(file)).toBe(true);
		expect(a.load()).toEqual([]);
	});

	test("repeated loads neither overwrite another store nor resurrect cleared rows", () => {
		const file = databasePath();
		const a = new PromptHistoryStore(file);
		const b = new PromptHistoryStore(file);
		a.append("old");
		expect(a.load()).toEqual(["old"]);
		b.append("new");
		for (let index = 0; index < 3; index++) expect(a.load()).toEqual(["old", "new"]);
		b.clear();
		for (let index = 0; index < 3; index++) expect(a.load()).toEqual([]);
		b.append("after clear");
		expect(a.load()).toEqual(["after clear"]);
		a.append("after clear");
		expectRows(file, ["after clear"]);
	});

	test("FULL auto-vacuum keeps physical pages bounded at steady state", () => {
		const file = databasePath();
		const maxEntries = 4;
		const prompt = (index: number) => `${index.toString().padStart(6, "0")}:${"s".repeat(6000)}`;
		const maxBytes = encodedBytes(prompt(0)) * maxEntries;
		const store = new PromptHistoryStore(file, { maxBytes, maxEntries });
		for (let index = 0; index < 24; index++) store.append(prompt(index));
		const warm = pageState(file);
		expect(warm.autoVacuum).toBe(1);
		const samples: number[] = [];
		for (let batch = 0; batch < 8; batch++) {
			for (let index = 0; index < 16; index++) store.append(prompt(24 + batch * 16 + index));
			const state = pageState(file);
			expect(state.autoVacuum).toBe(1);
			expect(state.freePages).toBe(0);
			expect(statSync(file).size).toBe(state.pages * state.pageSize);
			expect(rows(file)).toHaveLength(maxEntries);
			expect(rows(file).reduce((sum, row) => sum + row.bytes, 0)).toBe(maxBytes);
			samples.push(state.pages);
		}
		// SQLite headers, indexes and page slack are not logical prompt bytes.
		expect(statSync(file).size).toBeGreaterThan(maxBytes);
		expect(Math.max(...samples)).toBeLessThanOrEqual(warm.pages + 8);
		expect(store.load()).toEqual([148, 149, 150, 151].map(prompt));
		store.clear();
		expect(pageState(file).pages).toBeLessThan(warm.pages);
		expect(pageState(file).freePages).toBe(0);
		expectRows(file, []);
		expectDeleteJournal(file);
	}, 15000);
});

describe("PromptHistoryStore SQLite privacy and errors", () => {
	test("creates the owner directory as 0700 and database as 0600 under umask zero", () => {
		const previous = process.umask(0);
		try {
			const file = getPromptHistoryPath();
			new PromptHistoryStore().append("secret");
			expect(mode(dirname(file))).toBe(0o700);
			expect(mode(file)).toBe(0o600);
			expect(statSync(dirname(file)).uid).toBe(process.getuid?.() ?? -1);
			expect(statSync(file).uid).toBe(process.getuid?.() ?? -1);
			expect(statSync(file).nlink).toBe(1);
			expectDeleteJournal(file);
		} finally {
			process.umask(previous);
		}
	});

	test("tightens an existing database file but refuses a loose owner directory", () => {
		const file = databasePath();
		const store = new PromptHistoryStore(file);
		store.append("secret");
		chmodSync(file, 0o666);
		expect(store.load()).toEqual(["secret"]);
		expect(mode(file)).toBe(0o600);
		chmodSync(dirname(file), 0o755);
		try {
			for (const operation of [
				() => store.load(),
				() => store.append("new"),
				() => store.clear(),
			]) {
				expect(failure(operation).message).toMatch(/private|0700|700|permission/i);
			}
			expect(mode(dirname(file))).toBe(0o755);
		} finally {
			chmodSync(dirname(file), 0o700);
		}
		expectRows(file, ["secret"]);
	});

	test("disabled load and append perform no filesystem or SQLite calls", async () => {
		const file = databasePath();
		const result = await runWorker(file, { op: "disabled-no-io" });
		expect(result).toEqual({ event: "done", prompts: [], ioCalls: 0 });
		expect(existsSync(dirname(file))).toBe(false);
	});

	test("disabled stores leave existing bytes untouched, but clear still empties the database", () => {
		const file = databasePath();
		new PromptHistoryStore(file).append("old secret");
		const before = readFileSync(file);
		const inode = statSync(file).ino;
		const disabled = new PromptHistoryStore(file, { enabled: false });
		expect(disabled.load()).toEqual([]);
		disabled.append("not saved");
		expect(readFileSync(file)).toEqual(before);
		disabled.clear();
		expect(statSync(file).ino).toBe(inode);
		expectRows(file, []);
		expect(new PromptHistoryStore(file).load()).toEqual([]);
	});

	test("load exposes corrupt databases and unusable paths instead of returning empty history", () => {
		const file = databasePath();
		mkdirSync(dirname(file), { mode: 0o700 });
		writeFileSync(file, "not a SQLite database", { mode: 0o600 });
		const store = new PromptHistoryStore(file);
		for (const operation of [() => store.load(), () => store.append("new"), () => store.clear()]) {
			expect(failure(operation).message).toMatch(/history|database|SQLite/i);
		}
		expect(readFileSync(file, "utf8")).toBe("not a SQLite database");
		const blocker = join(home, "blocker");
		writeFileSync(blocker, "untouched");
		const blocked = new PromptHistoryStore(join(blocker, "private", "history.sqlite3"));
		for (const operation of [
			() => blocked.load(),
			() => blocked.append("x"),
			() => blocked.clear(),
		]) {
			expect(failure(operation).message).toMatch(/history|directory|ENOTDIR/i);
		}
		expect(readFileSync(blocker, "utf8")).toBe("untouched");
	});

	test.skipIf(process.getuid?.() === 0)(
		"load, append and clear report a real EACCES without erasing committed rows",
		() => {
			const ancestor = join(home, "inaccessible");
			const file = join(ancestor, "private", "history.sqlite3");
			mkdirSync(ancestor, { mode: 0o700 });
			const store = new PromptHistoryStore(file);
			store.append("committed secret");
			chmodSync(ancestor, 0);
			try {
				for (const operation of [
					() => store.load(),
					() => store.append("new"),
					() => store.clear(),
				]) {
					const error = failure(operation);
					expect(error.code).toBe("EACCES");
					expect(error.message).toMatch(/history/i);
					expect(error.message).toMatch(/EACCES|permission denied|access/i);
				}
			} finally {
				chmodSync(ancestor, 0o700);
			}
			expectRows(file, ["committed secret"]);
		},
	);

	for (const kind of [
		"database symlink",
		"database hardlink",
		"private directory symlink",
	] as const) {
		test(`refuses a ${kind} without changing its target`, () => {
			const file = databasePath();
			const target = join(home, "target");
			if (kind === "private directory symlink") {
				mkdirSync(target, { mode: 0o700 });
				writeFileSync(join(target, "sentinel"), "untouched", { mode: 0o600 });
				symlinkSync(target, dirname(file));
			} else {
				mkdirSync(dirname(file), { mode: 0o700 });
				writeFileSync(target, "untouched", { mode: 0o600 });
				if (kind === "database symlink") symlinkSync(target, file);
				else linkSync(target, file);
			}
			const store = new PromptHistoryStore(file);
			for (const operation of [
				() => store.load(),
				() => store.append("new"),
				() => store.clear(),
			]) {
				expect(failure(operation).message).toMatch(/symlink|symbolic|link|private|regular/i);
			}
			if (kind === "private directory symlink") {
				expect(readdirSync(target)).toEqual(["sentinel"]);
				expect(readFileSync(join(target, "sentinel"), "utf8")).toBe("untouched");
			} else {
				expect(readFileSync(target, "utf8")).toBe("untouched");
				expect(mode(target)).toBe(0o600);
			}
		});
	}

	for (const suffix of ["-journal", "-wal", "-shm"]) {
		for (const kind of ["symlink", "hardlink", "directory"] as const) {
			test(`refuses a ${kind} at the SQLite ${suffix} path`, () => {
				const file = databasePath();
				const store = new PromptHistoryStore(file);
				store.append("committed");
				const sidecar = `${file}${suffix}`;
				const target = join(home, "sidecar-target");
				writeFileSync(target, "untouched", { mode: 0o600 });
				if (kind === "symlink") symlinkSync(target, sidecar);
				else if (kind === "hardlink") linkSync(target, sidecar);
				else mkdirSync(sidecar, { mode: 0o700 });
				for (const operation of [
					() => store.load(),
					() => store.append("new"),
					() => store.clear(),
				]) {
					expect(failure(operation).message).toMatch(
						/symlink|symbolic|link|regular|directory|sidecar|unsafe/i,
					);
				}
				expect(readFileSync(target, "utf8")).toBe("untouched");
				expect(mode(target)).toBe(0o600);
				rmSync(sidecar, { recursive: true });
				expect(store.load()).toEqual(["committed"]);
			});
		}
	}

	test("handles safe 0600 sidecars from an external WAL connection without losing committed rows", () => {
		const file = databasePath();
		const store = new PromptHistoryStore(file);
		store.append("before WAL");
		const external = new Database(file);
		try {
			external.exec("PRAGMA journal_mode = WAL");
			external
				.query("INSERT INTO prompts (prompt, bytes) VALUES (?, ?)")
				.run("external WAL commit", encodedBytes("external WAL commit"));
			for (const suffix of ["-wal", "-shm"]) {
				expect(existsSync(`${file}${suffix}`)).toBe(true);
				expect(mode(`${file}${suffix}`)).toBe(0o600);
			}
			let loaded: string[] | undefined;
			let storageError: unknown;
			try {
				loaded = store.load();
			} catch (error) {
				storageError = error;
			}
			if (storageError !== undefined) {
				// An open external WAL connection may prevent the switch back to DELETE.
				expect(storageError).toBeInstanceOf(Error);
				expect((storageError as Error).message).toMatch(/busy|locked/i);
				expect((storageError as Error).message).toMatch(/history/i);
			} else {
				expect(loaded).toEqual(["before WAL", "external WAL commit"]);
			}
			expect(external.query("SELECT prompt FROM prompts ORDER BY id").all()).toEqual([
				{ prompt: "before WAL" },
				{ prompt: "external WAL commit" },
			]);
		} finally {
			external.close();
		}
		expect(store.load()).toEqual(["before WAL", "external WAL commit"]);
		expectRows(file, ["before WAL", "external WAL commit"]);
		expect(inspect(file, (database) => database.query("PRAGMA journal_mode").get())).toEqual({
			journal_mode: "delete",
		});
		// Apple's SQLite may leave inert WAL/SHM files after changing journal
		// mode. Do not unlink sidecars behind another connection's back; assert
		// privacy and no growth instead of assuming platform-specific cleanup.
		const residual = ["-wal", "-shm"].map((suffix) => ({
			suffix,
			size: existsSync(`${file}${suffix}`) ? statSync(`${file}${suffix}`).size : 0,
		}));
		for (let index = 0; index < 8; index++) store.append(`after WAL ${index}`);
		for (const { suffix, size } of residual) {
			if (existsSync(`${file}${suffix}`)) {
				expect(mode(`${file}${suffix}`)).toBe(0o600);
				expect(statSync(`${file}${suffix}`).size).toBeLessThanOrEqual(size);
			}
		}
	});
});

describe("PromptHistoryStore independent SQLite transactions", () => {
	test("concurrent processes preserve every committed row in database transaction order", async () => {
		const file = databasePath();
		new PromptHistoryStore(file).clear();
		const prompts = (writer: number) =>
			Array.from({ length: 12 }, (_, index) => `writer-${writer}:${index}`);
		const writers = Array.from({ length: 4 }, (_, index) =>
			spawnWorker(file, { op: "append", prompts: prompts(index), maxEntries: 1000 }),
		);
		await Promise.all(writers.map((writer) => writer.event("ready")));
		await Promise.all(writers.map((writer) => writer.release()));
		await Promise.all(writers.map((writer) => writer.event("started")));
		expect(await Promise.all(writers.map((writer) => writer.finish()))).toEqual(
			Array.from({ length: 4 }, () => ({ event: "done" })),
		);
		const committed = rows(file).map((row) => row.prompt);
		expect(committed).toHaveLength(48);
		expect([...committed].sort()).toEqual(
			Array.from({ length: 4 }, (_, index) => prompts(index))
				.flat()
				.sort(),
		);
		for (let index = 0; index < 4; index++) {
			expect(committed.filter((prompt) => prompt.startsWith(`writer-${index}:`))).toEqual(
				prompts(index),
			);
		}
		// Row IDs, not stdout arrival times or process clocks, define commit order.
		expect(new PromptHistoryStore(file, { maxEntries: 1000 }).load()).toEqual(committed);
		expectRows(file, committed);
		expectDeleteJournal(file);
	}, 15000);

	test("a writer waits for BEGIN IMMEDIATE and appends after the held commit", async () => {
		const file = databasePath();
		const store = new PromptHistoryStore(file);
		store.append("seed");
		const holder = await startWorker(file, {
			op: "hold-insert",
			prompts: ["held commit"],
			umask: 0,
		});
		await holder.event("holding");
		expect(mode(`${file}-journal`)).toBe(0o600);
		expect(mode(file)).toBe(0o600);
		expect(mode(dirname(file))).toBe(0o700);
		expectRows(file, ["seed"]);
		const writer = await startWorker(file, { op: "append", prompts: ["waiting writer"] });
		await holder.release();
		expect(await holder.finish()).toEqual({ event: "done" });
		expect(await writer.finish()).toEqual({ event: "done" });
		expectRows(file, ["seed", "held commit", "waiting writer"]);
		expect(store.load()).toEqual(["seed", "held commit", "waiting writer"]);
		expectDeleteJournal(file);
	}, 15000);

	test("a repeat queued behind an uncommitted insert deduplicates only after that commit", async () => {
		const file = databasePath();
		new PromptHistoryStore(file).append("seed");
		const holder = await startWorker(file, { op: "hold-insert", prompts: ["same"] });
		await holder.event("holding");
		const writer = await startWorker(file, { op: "append", prompts: ["same"] });
		await holder.release();
		expect(await holder.finish()).toEqual({ event: "done" });
		expect(await writer.finish()).toEqual({ event: "done" });
		expectRows(file, ["seed", "same"]);
	}, 15000);

	test("clear serializes after an open write, and a prestarted later writer survives the clear", async () => {
		const file = databasePath();
		const store = new PromptHistoryStore(file);
		store.append("seed");
		const inode = statSync(file).ino;
		const holder = await startWorker(file, { op: "hold-insert", prompts: ["before clear"] });
		await holder.event("holding");
		const later = spawnWorker(file, { op: "append", prompts: ["after clear"] });
		await later.event("ready");
		const clearer = await startWorker(file, { op: "clear" });
		await holder.release();
		expect(await holder.finish()).toEqual({ event: "done" });
		expect(await clearer.finish()).toEqual({ event: "done" });
		expectRows(file, []);
		expect(statSync(file).ino).toBe(inode);
		await later.release();
		await later.event("started");
		expect(await later.finish()).toEqual({ event: "done" });
		expect(store.load()).toEqual(["after clear"]);
		expectRows(file, ["after clear"]);
		expectDeleteJournal(file);
	}, 15000);

	test("SIGKILL rolls back an uncommitted writer and preserves all earlier committed history", async () => {
		const file = databasePath();
		const store = new PromptHistoryStore(file);
		for (const prompt of ["committed one", "committed two"]) store.append(prompt);
		const holder = await startWorker(file, {
			op: "hold-insert",
			prompts: [`must roll back:${"x".repeat(64 * 1024)}`],
			spill: true,
		});
		await holder.event("holding");
		expect(existsSync(`${file}-journal`)).toBe(true);
		expect(statSync(`${file}-journal`).size).toBeGreaterThan(0);
		await holder.kill();
		expect(store.load()).toEqual(["committed one", "committed two"]);
		store.append("after recovery");
		expectRows(file, ["committed one", "committed two", "after recovery"]);
		expect(inspect(file, (database) => database.query("PRAGMA integrity_check").get())).toEqual({
			integrity_check: "ok",
		});
		expectDeleteJournal(file);
	}, 15000);

	test("a held writer produces a finite, actionable busy timeout rather than an unbounded wait", async () => {
		const file = databasePath();
		new PromptHistoryStore(file).append("committed");
		const holder = await startWorker(file, { op: "hold-insert", prompts: ["held"] });
		await holder.event("holding");
		const result = await runWorker(file, { op: "append", prompts: ["timed out"] });
		expect(result.event).toBe("error");
		expect(result.message).toMatch(/busy|locked/i);
		expect(result.message).toMatch(/history/i);
		expect(result.elapsedMs).toBeGreaterThanOrEqual(1000);
		expect(result.elapsedMs).toBeLessThan(4000);
		expectRows(file, ["committed"]);
		await holder.release();
		expect(await holder.finish()).toEqual({ event: "done" });
		expectRows(file, ["committed", "held"]);
	}, 15000);
});

describe("PromptHistoryStore one-shot legacy import", () => {
	test("imports base, numeric and timestamp-pid-random sources once in deterministic source order", () => {
		const oldest = writeLegacySource(2, ["numeric oldest", "shared"]);
		const newer = writeLegacySource(1, ["shared", "numeric newer"]);
		const namedOlder = writeLegacySource("1700000000000-12-0000000000000001", ["named older"]);
		const namedNewer = writeLegacySource("1700000000001-12-0000000000000002", ["named newer"]);
		const base = writeLegacySource(undefined, ["base newest"]);
		// Import ordering is a deterministic tie-breaker, not a claim about file mtimes.
		for (const [index, path] of [oldest, newer, namedOlder, namedNewer, base].entries()) {
			utimesSync(path, 100 - index, 100 - index);
		}
		const ignored = writeLegacySource("notes", ["not a history source"]);
		const store = new PromptHistoryStore();
		const expected = [
			"numeric oldest",
			"shared",
			"numeric newer",
			"named older",
			"named newer",
			"base newest",
		];
		expect(store.load()).toEqual(expected);
		expectRows(getPromptHistoryPath(), expected);
		expect(migrationMarker(getPromptHistoryPath())).not.toBeNull();
		for (const path of [oldest, newer, namedOlder, namedNewer, base]) {
			expect(existsSync(path)).toBe(false);
			writeFileSync(path, encode(["must not import again"]), { mode: 0o600 });
		}
		for (let index = 0; index < 2; index++)
			expect(new PromptHistoryStore().load()).toEqual(expected);
		expectRows(getPromptHistoryPath(), expected);
		expect(readFileSync(ignored, "utf8")).toBe(encode(["not a history source"]));
	});

	test("legacy import skips malformed and oversized records and applies both logical bounds", () => {
		writeLegacySource(2, ["old", "λ".repeat(10)]);
		const base = writeLegacySource(undefined, []);
		writeFileSync(
			base,
			`${encode(["x".repeat(500), "🌱".repeat(5)])}{broken\n42\n"   "\n${encode(["last"])}`,
		);
		const store = new PromptHistoryStore(undefined, { maxBytes: 52, maxEntries: 2 });
		expect(store.load()).toEqual(["🌱".repeat(5), "last"]);
		expectRows(getPromptHistoryPath(), ["🌱".repeat(5), "last"]);
		expect(migrationMarker(getPromptHistoryPath())).not.toBeNull();
	});

	test("a crash partway through import rolls back the rows and marker before retrying once", async () => {
		const oldest = writeLegacySource(2, ["first source"]);
		const base = writeLegacySource(undefined, ["second source"]);
		const worker = await startWorker(getPromptHistoryPath(), { op: "load", pauseLegacyRead: 2 });
		await worker.event("import-paused");
		// The first source was inserted, but neither rows nor the marker have committed.
		expect(readFileSync(oldest, "utf8")).toBe(encode(["first source"]));
		expect(readFileSync(base, "utf8")).toBe(encode(["second source"]));
		await worker.kill();
		const store = new PromptHistoryStore();
		expect(store.load()).toEqual(["first source", "second source"]);
		expect(store.load()).toEqual(["first source", "second source"]);
		expectRows(getPromptHistoryPath(), ["first source", "second source"]);
		expect(migrationMarker(getPromptHistoryPath())).not.toBeNull();
		expect(existsSync(oldest)).toBe(false);
		expect(existsSync(base)).toBe(false);
	}, 15000);

	for (const op of ["load", "clear"] as const) {
		test(`a crash during ${op} legacy cleanup cannot import committed or cleared sources again`, async () => {
			const oldest = writeLegacySource(2, ["older legacy"]);
			const base = writeLegacySource(undefined, ["base legacy"]);
			const worker = await startWorker(getPromptHistoryPath(), {
				op,
				enabled: op !== "clear",
				pauseLegacyCleanup: oldest,
			});
			await worker.event("cleanup-paused");
			const expected = op === "load" ? ["older legacy", "base legacy"] : [];
			// The cleanup barrier is strictly after the transaction and connection close.
			expect(migrationMarker(getPromptHistoryPath())).not.toBeNull();
			expectRows(getPromptHistoryPath(), expected);
			expect(existsSync(oldest)).toBe(true);
			await worker.kill();
			writeFileSync(oldest, encode(["older legacy"]), { mode: 0o600 });
			writeFileSync(base, encode(["base legacy"]), { mode: 0o600 });
			const store = new PromptHistoryStore();
			expect(store.load()).toEqual(expected);
			expect(store.load()).toEqual(expected);
			store.append("fresh after crash");
			expectRows(getPromptHistoryPath(), [...expected, "fresh after crash"]);
		}, 15000);
	}

	test("clear while disabled marks migration before cleanup and prevents later resurrection", () => {
		const sources = [
			writeLegacySource(2, ["old numeric"]),
			writeLegacySource("1700000000000-12-0000000000000001", ["old named"]),
			writeLegacySource(undefined, ["old base"]),
		];
		const disabled = new PromptHistoryStore(undefined, { enabled: false });
		expect(disabled.load()).toEqual([]);
		disabled.append("not persisted");
		expect(existsSync(getPromptHistoryPath())).toBe(false);
		for (const path of sources) expect(existsSync(path)).toBe(true);
		disabled.clear();
		expectRows(getPromptHistoryPath(), []);
		expect(migrationMarker(getPromptHistoryPath())).not.toBeNull();
		for (const path of sources) {
			expect(existsSync(path)).toBe(false);
			writeFileSync(path, encode(["leftover old secret"]), { mode: 0o600 });
		}
		const enabled = new PromptHistoryStore();
		expect(enabled.load()).toEqual([]);
		enabled.append("new submitted prompt");
		expectRows(getPromptHistoryPath(), ["new submitted prompt"]);
	});

	test.skipIf(process.getuid?.() === 0)(
		"a real legacy cleanup EACCES is reported after clear without permitting resurrection",
		() => {
			const store = new PromptHistoryStore();
			store.append("committed secret");
			const source = writeLegacySource(2, ["old legacy secret"]);
			const legacyDirectory = dirname(source);
			chmodSync(legacyDirectory, 0o500);
			try {
				const disabled = new PromptHistoryStore(undefined, { enabled: false });
				const error = failure(() => disabled.clear());
				expect(error.code).toBe("EACCES");
				expect(error.message).toMatch(/clear prompt history/i);
				expectRows(getPromptHistoryPath(), []);
				expect(migrationMarker(getPromptHistoryPath())).not.toBeNull();
				expect(existsSync(source)).toBe(true);
			} finally {
				chmodSync(legacyDirectory, 0o700);
			}
			expect(store.load()).toEqual([]);
			expect(existsSync(source)).toBe(false);
			store.append("fresh");
			expectRows(getPromptHistoryPath(), ["fresh"]);
		},
	);
});
