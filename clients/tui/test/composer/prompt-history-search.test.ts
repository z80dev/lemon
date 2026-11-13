import { Database } from "bun:sqlite";
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PromptHistoryStore } from "../../src/composer/prompt-history.ts";
import { createHistorySource } from "../../src/ui/history-search.ts";

let home: string;
let file: string;

beforeEach(() => {
	home = mkdtempSync(join(tmpdir(), "lemon-history-search-"));
	file = join(home, "private", "history.sqlite3");
});

afterEach(() => {
	rmSync(home, { recursive: true, force: true });
});

describe("PromptHistoryStore search", () => {
	test("lists saved prompts newest first with their time and folder", () => {
		const store = new PromptHistoryStore(file);
		store.append("first prompt", "/work/a");
		store.append("second prompt", "/work/b");
		store.append("third prompt");

		const recent = store.recent(10);
		expect(recent.map((entry) => entry.prompt)).toEqual([
			"third prompt",
			"second prompt",
			"first prompt",
		]);
		expect(recent[1]?.cwd).toBe("/work/b");
		expect(recent[0]).not.toHaveProperty("cwd");
		expect(Math.abs((recent[0]?.created_at ?? 0) - Date.now() / 1000)).toBeLessThan(60);
		expect(store.recent(2)).toHaveLength(2);
	});

	test("search needs every token, ignores case and punctuation, and keeps newest first", () => {
		const store = new PromptHistoryStore(file);
		store.append("Refactor the Parser module");
		store.append("write docs");
		store.append("parser: fix the lexer");

		expect(store.search("PARSER", 10).map((entry) => entry.prompt)).toEqual([
			"parser: fix the lexer",
			"Refactor the Parser module",
		]);
		expect(store.search("parser, the module", 10).map((entry) => entry.prompt)).toEqual([
			"Refactor the Parser module",
		]);
		expect(store.search("parser", 1)).toHaveLength(1);
		expect(store.search("nothing matches", 10)).toEqual([]);
		expect(store.search("  ", 10)).toHaveLength(3);
	});

	test("matches non-ASCII text case-insensitively", () => {
		const store = new PromptHistoryStore(file);
		store.append("Über die Brücke");
		expect(store.search("über", 10).map((entry) => entry.prompt)).toEqual(["Über die Brücke"]);
	});

	test("a disabled store neither writes nor reads", () => {
		const store = new PromptHistoryStore(file, { enabled: false });
		store.append("never saved");
		expect(store.recent(10)).toEqual([]);
		expect(store.search("saved", 10)).toEqual([]);
		expect(store.enabled).toBe(false);
	});

	test("adds created_at and cwd to a database from before the search overlay", () => {
		mkdirSync(join(home, "private"), { mode: 0o700 });
		chmodSync(join(home, "private"), 0o700);
		const old = new Database(file, { create: true });
		old.exec(
			"CREATE TABLE prompts (id INTEGER PRIMARY KEY, prompt TEXT NOT NULL, bytes INTEGER NOT NULL); CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL); INSERT INTO metadata VALUES ('legacy_migrated', '1')",
		);
		old.run("INSERT INTO prompts(prompt, bytes) VALUES ('from an old version', 24)");
		old.close();
		chmodSync(file, 0o600);

		const store = new PromptHistoryStore(file);
		store.append("from this version", "/here");

		const [newest, oldest] = store.recent(10);
		expect(newest).toMatchObject({ prompt: "from this version", cwd: "/here" });
		expect(oldest?.prompt).toBe("from an old version");
		expect(oldest?.created_at).toBeGreaterThan(0);
		expect(oldest).not.toHaveProperty("cwd");
		// Loading (the ↑ ring) is unaffected by the new columns.
		expect(store.load()).toEqual(["from an old version", "from this version"]);
	});

	test("clear removes timestamps and folders with the prompts", () => {
		const store = new PromptHistoryStore(file);
		store.append("secret", "/private/place");
		store.clear();
		expect(store.recent(10)).toEqual([]);
		const db = new Database(file, { readonly: true });
		try {
			expect(db.query("SELECT count(*) AS n FROM prompts").get()).toEqual({ n: 0 });
		} finally {
			db.close();
		}
	});
});

describe("createHistorySource", () => {
	test("searches the store when persistence is on, ignoring the ring", () => {
		const store = new PromptHistoryStore(file);
		store.append("saved prompt");
		const source = createHistorySource({ store, memory: () => ["draft only"] });
		expect(source.getRecent(10).map((entry) => entry.prompt)).toEqual(["saved prompt"]);
		expect(source.search("saved", 10)).toHaveLength(1);
		expect(source.search("draft", 10)).toEqual([]);
	});

	test("falls back to the in-memory ring, newest first, when persistence is off", () => {
		const store = new PromptHistoryStore(file, { enabled: false });
		const source = createHistorySource({
			store,
			memory: () => ["alpha one", "beta", "alpha two"],
		});
		expect(source.getRecent(10).map((entry) => entry.prompt)).toEqual([
			"alpha two",
			"beta",
			"alpha one",
		]);
		expect(source.search("alpha", 1).map((entry) => entry.prompt)).toEqual(["alpha two"]);
		expect(createHistorySource({ memory: () => ["x"] }).getRecent(5)).toHaveLength(1);
	});

	test("reports a storage failure once and keeps answering from the ring", () => {
		// A directory where the database file should be makes every operation fail.
		mkdirSync(file, { recursive: true });
		const store = new PromptHistoryStore(file);
		const errors: unknown[] = [];
		const source = createHistorySource({
			store,
			memory: () => ["still here"],
			onStorageError: (error) => errors.push(error),
		});
		expect(source.getRecent(10).map((entry) => entry.prompt)).toEqual(["still here"]);
		expect(source.search("still", 10)).toHaveLength(1);
		expect(errors).toHaveLength(1);
	});
});
