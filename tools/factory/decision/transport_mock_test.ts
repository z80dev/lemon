import { test, expect } from "bun:test";
import { Database } from "bun:sqlite";
import { chmodSync, existsSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { CATALOG, MODEL, ReadOnlyCredentialStore, resolveOmpKey, runTransport } from "./omp_transport";

const payload = { model: MODEL, state: {}, questions: { complexity: { type: "choice", criteria: { simple: "a", standard: "b", complex: "c", insufficient_information: "d" } } } };
const catalog = () => Response.json({ data: { id: MODEL, architecture: { output_modalities: ["decisions"] }, endpoints: [{ status: 0 }] } });
const key = async () => "synthetic-secret";

test("missing key never posts", async () => {
	let calls = 0;
	const result = await runTransport(payload, 1000, { resolveKey: async () => undefined, fetch: (async () => { calls++; return catalog(); }) as typeof fetch });
	expect(calls).toBe(1);
	expect(result.error_class).toBe("credential_unavailable");
});

test("catalog failure closes before key resolution or POST", async () => {
	const result = await runTransport(payload, 1000, { resolveKey: async () => { throw new Error("must not resolve"); }, fetch: (async () => new Response("private", { status: 503 })) as typeof fetch });
	expect(result).toEqual({ status: 503, body: {}, error_class: "catalog_unavailable" });
});

test("malicious HTTP echo never escapes", async () => {
	const result = await runTransport(payload, 1000, { resolveKey: key, fetch: (async url => url === CATALOG ? catalog() : new Response("synthetic-secret", { status: 401 })) as typeof fetch });
	expect(result).toEqual({ status: 401, body: {}, error_class: "http_error" });
});

test("all fetches refuse redirects and discard thrown text", async () => {
	let calls = 0;
	const result = await runTransport(payload, 1000, { resolveKey: key, fetch: (async (_url, init) => {
		expect(init?.redirect).toBe("error");
		if (++calls === 1) return catalog();
		throw new Error("synthetic-secret redirect");
	}) as typeof fetch });
	expect(result.error_class).toBe("transport_unavailable");
	expect(JSON.stringify(result)).not.toContain("synthetic-secret");
});

test("deadline abort becomes generic timeout", async () => {
	const result = await runTransport(payload, 5, { resolveKey: key, fetch: (async (_url, init) => {
		await Bun.sleep(15);
		init?.signal?.throwIfAborted();
		return catalog();
	}) as typeof fetch });
	expect(result.error_class).toBe("timeout");
});

test("success contains only fixed choices and safe numeric fields", async () => {
	const result = await runTransport(payload, 1000, { resolveKey: key, fetch: (async url => url === CATALOG ? catalog() : Response.json({ model: MODEL, answers: { complexity: { type: "choice", choice: "simple", confidence: 0.8, explanation: "synthetic-secret" } }, usage: { input_tokens: 3, output_tokens: 1, cost: 0, secret: "synthetic-secret" } })) as typeof fetch });
	expect(result.error_class).toBeNull();
	expect(JSON.stringify(result)).not.toContain("synthetic-secret");
});

test("facade reads enabled openrouter API keys only and refuses writes", () => {
	const dir = mkdtempSync(join(tmpdir(), "factory-decision-"));
	const path = join(dir, "fake.db");
	try {
		const db = new Database(path);
		db.exec("CREATE TABLE auth_credentials(id INTEGER, provider TEXT, credential_type TEXT, data TEXT, disabled_cause TEXT)");
		const insert = db.query("INSERT INTO auth_credentials VALUES (?, ?, ?, ?, ?)");
		insert.run(1, "openrouter", "api_key", JSON.stringify({ key: "fake", source: "login" }), null);
		insert.run(2, "openrouter", "api_key", JSON.stringify({ key: "disabled" }), "disabled");
		insert.run(3, "other", "api_key", JSON.stringify({ key: "other" }), null);
		db.close();
		chmodSync(path, 0o600);
		const store = new ReadOnlyCredentialStore(path);
		try {
			expect(store.listAuthCredentials()).toEqual([{ id: 1, provider: "openrouter", disabledCause: null, credential: { type: "api_key", key: "fake", source: "login" } }]);
			expect(store.getCache()).toBeNull();
			expect(() => store.cleanExpiredCache()).toThrow("read_only");
			expect(() => store.deleteAuthCredential()).toThrow("read_only");
		} finally { store.close(); }
		chmodSync(path, 0o644);
		expect(() => new ReadOnlyCredentialStore(path)).toThrow("read_only");
	} finally { rmSync(dir, { recursive: true, force: true }); }
});

test("actual OMP resolver reads fake database without mutation", async () => {
	const executable = Bun.which("omp");
	expect(executable).not.toBeNull();
	let root = dirname(realpathSync(executable!));
	while (!existsSync(join(root, "packages/ai/src/auth-storage.ts"))) {
		const parent = dirname(root);
		if (parent === root) throw new Error("installed_omp_source_unavailable");
		root = parent;
	}
	const dir = mkdtempSync(join(tmpdir(), "factory-resolver-"));
	const path = join(dir, "fake.db");
	try {
		const db = new Database(path);
		db.exec("CREATE TABLE auth_credentials(id INTEGER, provider TEXT, credential_type TEXT, data TEXT, disabled_cause TEXT)");
		db.query("INSERT INTO auth_credentials VALUES (1, 'openrouter', 'api_key', ?, NULL)").run(JSON.stringify({ key: "synthetic-resolver-key", source: "login" }));
		db.close();
		chmodSync(path, 0o600);
		const before = await Bun.file(path).bytes();
		expect(await resolveOmpKey(root, path)).toBe("synthetic-resolver-key");
		expect(await Bun.file(path).bytes()).toEqual(before);
	} finally { rmSync(dir, { recursive: true, force: true }); }
});
