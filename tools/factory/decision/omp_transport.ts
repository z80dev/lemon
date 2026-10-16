import { Database } from "bun:sqlite";
import { lstatSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

export const MODEL = "cloudflare/clef-flash";
export const ENDPOINT = "https://openrouter.ai/api/v1/systemone";
export const CATALOG = "https://openrouter.ai/api/v1/models/cloudflare/clef-flash/endpoints";
const LIMIT = 65536;
const CHOICES = ["simple", "standard", "complex", "insufficient_information"];
type ObjectValue = Record<string, unknown>;
const object = (v: unknown): ObjectValue => v !== null && typeof v === "object" && !Array.isArray(v) ? v as ObjectValue : {};
const finite = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v) && v >= 0;
const refuse = (): never => { throw new Error("read_only"); };

/** No DDL, cache, hygiene, refresh or credential mutation is permitted. */
export class ReadOnlyCredentialStore {
	#db: Database;
	constructor(path: string) {
		const stat = lstatSync(path);
		if (!stat.isFile() || stat.uid !== process.getuid?.() || (stat.mode & 0o077) !== 0) refuse();
		this.#db = new Database(path, { readonly: true, create: false });
		this.#db.exec("PRAGMA query_only = ON");
	}
	close() { this.#db.close(); }
	listAuthCredentials(provider?: string) {
		if (provider !== undefined && provider !== "openrouter") return [];
		const rows = this.#db.query("SELECT id, data FROM auth_credentials WHERE provider = 'openrouter' AND credential_type = 'api_key' AND disabled_cause IS NULL ORDER BY id ASC").all() as { id: number; data: string }[];
		return rows.flatMap(row => {
			const data = object(JSON.parse(row.data));
			if (typeof data.key !== "string" || !data.key.trim()) return [];
			return [{ id: row.id, provider: "openrouter", disabledCause: null, credential: { type: "api_key", key: data.key, ...(data.source === "login" ? { source: "login" } : {}) } }];
		});
	}
	getCache() { return null; }
	updateAuthCredential = refuse;
	deleteAuthCredential = refuse;
	tryDisableAuthCredentialIfMatches = refuse;
	replaceAuthCredentialsForProvider = refuse;
	upsertAuthCredentialForProvider = refuse;
	deleteAuthCredentialsForProvider = refuse;
	setCache = refuse;
	cleanExpiredCache = refuse;
	cleanExpiredCredentialBlocks = refuse;
	deleteCachePrefix = refuse;
}

/** Imported OMP owns credential selection; the facade exposes only enabled API keys. */
export async function resolveOmpKey(root: string, dbPath = join(homedir(), ".omp/agent/agent.db")): Promise<string | undefined> {
	const store = new ReadOnlyCredentialStore(dbPath);
	try {
		if (store.listAuthCredentials().length === 0) return undefined;
		// The installed source root is runtime-selected, so a static import cannot resolve it.
		const { AuthStorage } = await import(pathToFileURL(join(root, "packages/ai/src/auth-storage.ts")).href);
		const auth = new AuthStorage(store, { configValueResolver: async (value: string) => value });
		await auth.reload();
		return await auth.getApiKey("openrouter");
	} finally { store.close(); }
}

async function boundedJson(response: Response): Promise<ObjectValue> {
	if (!response.body) throw new Error("invalid_response");
	const reader = response.body.getReader();
	const chunks: Uint8Array[] = [];
	let size = 0;
	try {
		for (;;) {
			const { done, value } = await reader.read();
			if (done) break;
			size += value.byteLength;
			if (size > LIMIT) throw new Error("invalid_response");
			chunks.push(value);
		}
	} finally { await reader.cancel().catch(() => {}); }
	const bytes = new Uint8Array(size);
	let offset = 0;
	for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
	return object(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)));
}

type Dependencies = { resolveKey: () => Promise<string | undefined>; fetch: typeof fetch };
export async function runTransport(payload: ObjectValue, timeoutMs: number, dependencies: Dependencies) {
	const fail = (error_class: string, status: number | null = null) => ({ status, body: {}, error_class });
	if (payload.model !== MODEL) return fail("protocol_unavailable");
	if (object(object(payload.questions).complexity).type !== "choice" || Object.keys(object(payload.questions)).length !== 1) return fail("protocol_unavailable");
	const choices = Object.keys(object(object(object(payload.questions).complexity).criteria));
	if (choices.length !== CHOICES.length || !CHOICES.every(choice => choices.includes(choice))) return fail("protocol_unavailable");
	if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) return fail("timeout");
	let serialized: string;
	try { serialized = JSON.stringify(payload); } catch { return fail("protocol_unavailable"); }
	if (new TextEncoder().encode(serialized).byteLength > LIMIT) return fail("protocol_unavailable");
	const signal = AbortSignal.timeout(Math.max(1, Math.ceil(timeoutMs)));
	let catalogVerified = false;
	try {
		const catalog = await dependencies.fetch(CATALOG, { method: "GET", redirect: "error", signal });
		if (!catalog.ok) return fail("catalog_unavailable", catalog.status);
		const data = object((await boundedJson(catalog)).data);
		const architecture = object(data.architecture);
		const endpoints = Array.isArray(data.endpoints) ? data.endpoints : [];
		if (data.id !== MODEL || !Array.isArray(architecture.output_modalities) || !architecture.output_modalities.includes("decisions") || !endpoints.some(endpoint => object(endpoint).status === 0)) return fail("protocol_unavailable");
		catalogVerified = true;
		const keyResolution = Promise.withResolvers<never>();
		const abortKey = () => keyResolution.reject(new Error("timeout"));
		signal.addEventListener("abort", abortKey, { once: true });
		let key: string | undefined;
		try { key = await Promise.race([dependencies.resolveKey(), keyResolution.promise]); }
		finally { signal.removeEventListener("abort", abortKey); }
		if (typeof key !== "string" || !key.trim()) return fail("credential_unavailable");
		signal.throwIfAborted();
		const response = await dependencies.fetch(ENDPOINT, { method: "POST", redirect: "error", signal, headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` }, body: serialized });
		if (!response.ok) return fail("http_error", response.status);
		const raw = await boundedJson(response);
		if (raw.error !== undefined || raw.model !== MODEL || Object.keys(object(raw.answers)).length !== 1) return fail("protocol_invalid", response.status);
		const answer = object(object(raw.answers).complexity);
		if (answer.type !== "choice" || typeof answer.choice !== "string" || !choices.includes(answer.choice)) return fail("protocol_invalid", response.status);
		const clean: ObjectValue = { type: "choice", choice: answer.choice };
		if (answer.confidence !== undefined && (!finite(answer.confidence) || answer.confidence > 1)) return fail("protocol_invalid", response.status);
		if (finite(answer.confidence) && answer.confidence <= 1) clean.confidence = answer.confidence;
		if (answer.probabilities !== undefined) {
			const probabilities = object(answer.probabilities);
			const entries = Object.entries(probabilities);
			if (entries.length !== choices.length || !choices.every(choice => finite(probabilities[choice]) && (probabilities[choice] as number) <= 1)) return fail("protocol_invalid", response.status);
			clean.probabilities = Object.fromEntries(choices.map(choice => [choice, probabilities[choice]]));
		}
		const usage: ObjectValue = {};
		for (const field of ["input_tokens", "output_tokens", "cost"]) {
			const value = object(raw.usage)[field];
			if (value !== undefined && !finite(value)) return fail("protocol_invalid", response.status);
			if (finite(value)) usage[field] = value;
		}
		return { status: response.status, body: { model: MODEL, answers: { complexity: clean }, usage, catalog_verified: true }, error_class: null };
	} catch {
		return fail(signal.aborted ? "timeout" : catalogVerified ? "transport_unavailable" : "catalog_unavailable");
	}
}
if (import.meta.main) {
	// Imported diagnostics are suppressed, never replayed by Python.
	const output = process.stdout.write.bind(process.stdout);
	process.stdout.write = (() => true) as typeof process.stdout.write;
	process.stderr.write = (() => true) as typeof process.stderr.write;
	let result: unknown = { status: null, body: {}, error_class: "transport_unavailable" };
	try {
		const input = await boundedJson(new Response(Bun.stdin.stream()));
		result = await runTransport(object(input.payload), Number(input.timeout_ms), {
			resolveKey: () => resolveOmpKey(process.argv[2]), fetch,
		});
	} catch { /* Deliberately discard all arbitrary exception text. */ }
	output(JSON.stringify(result));
}
