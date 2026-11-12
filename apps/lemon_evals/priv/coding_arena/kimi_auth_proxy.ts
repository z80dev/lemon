/**
 * Host-side model auth proxy for isolated arena trials (Kimi Code and Z.AI).
 *
 * Trial containers never hold a real credential. Each trial receives an
 * HS256-signed JWT whose `sub` is its trial id; the proxy verifies it, swaps it
 * for the operator's real credential, and streams the upstream response back
 * unchanged. Routes:
 *
 *   /coding/...  → https://api.kimi.com/coding/...  Kimi Code OAuth access token from
 *                  `omp token kimi-code` (a JWT; omp alone owns refresh-token rotation)
 *   /zai/...     → https://api.z.ai/...             Z.AI API key from `omp token zai`
 *                  (static key, cached; refetched once after an upstream 401)
 *
 * Every request is attributed to its trial in a JSONL log (provider, model,
 * request shape sizes, status, latency, wire usage) without prompts, bodies or
 * tokens.
 *
 *   ARENA_PROXY_SECRET=... bun kimi_auth_proxy.ts --port 18787 --log /path/requests.jsonl
 */
import { appendFileSync } from "node:fs";
import { createHmac, timingSafeEqual } from "node:crypto";

const UPSTREAM = process.env.KIMI_UPSTREAM ?? "https://api.kimi.com";
const ZAI_UPSTREAM = process.env.ZAI_UPSTREAM ?? "https://api.z.ai";
const SECRET = process.env.ARENA_PROXY_SECRET;
if (!SECRET) throw new Error("ARENA_PROXY_SECRET is required");

const args = process.argv.slice(2);
const flag = (name: string, fallback: string) => {
	const index = args.indexOf(name);
	return index >= 0 ? args[index + 1] : fallback;
};
const port = Number(flag("--port", "18787"));
const host = flag("--host", "127.0.0.1");
const logPath = flag("--log", "");
const ompBin = flag("--omp", "omp");
const REFRESH_MARGIN_MS = 120_000;
// Fingerprint added only when a client sent none (Kimi gates on the Kimi CLI identity).
const FALLBACK_FINGERPRINT: Record<string, string> = {
	"user-agent": "KimiCLI/1.52.0",
	"x-msh-platform": "kimi_cli",
	"x-msh-version": "1.52.0",
	"x-msh-device-name": "lemon-arena",
	"x-msh-device-model": "Linux arena",
	"x-msh-os-version": "arena",
	"x-msh-device-id": "lemonarena00000000000000000000000",
};

function verifyTrialToken(token: string): string | undefined {
	const parts = token.split(".");
	if (parts.length !== 3) return undefined;
	const expected = createHmac("sha256", SECRET!).update(`${parts[0]}.${parts[1]}`).digest();
	const actual = Buffer.from(parts[2], "base64url");
	if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) return undefined;
	try {
		const claims = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
		return typeof claims.sub === "string" && claims.aud === "lemon-arena" ? claims.sub : undefined;
	} catch {
		return undefined;
	}
}

function jwtExpiryMs(token: string): number {
	try {
		const claims = JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8"));
		return typeof claims.exp === "number" ? claims.exp * 1000 : 0;
	} catch {
		return 0;
	}
}

type Credential = { token: string; expiresMs: number };

// One cache per omp credential: `kimi-code` is a JWT refreshed before expiry, `zai` a static key.
const credentials: Record<string, { cached?: Credential; inflight?: Promise<string> }> = { "kimi-code": {}, zai: {} };

async function fetchUpstreamToken(provider: string, force: boolean): Promise<string> {
	const argv = [ompBin, "token", provider, ...(force && provider === "kimi-code" ? ["--force-refresh"] : [])];
	const proc = Bun.spawn(argv, { stdout: "pipe", stderr: "pipe", stdin: "ignore" });
	const [stdout, code] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
	const token = stdout.trim().split("\n").pop()?.trim() ?? "";
	if (code !== 0 || !token) throw new Error(`omp token ${provider} failed (exit ${code})`);
	credentials[provider].cached = { token, expiresMs: provider === "kimi-code" ? jwtExpiryMs(token) : Infinity };
	return token;
}

async function upstreamToken(provider: string, force = false): Promise<string> {
	const slot = credentials[provider];
	if (!force && slot.cached && slot.cached.expiresMs - REFRESH_MARGIN_MS > Date.now()) return slot.cached.token;
	slot.inflight ??= fetchUpstreamToken(provider, force).finally(() => {
		slot.inflight = undefined;
	});
	return slot.inflight;
}

function log(entry: Record<string, unknown>) {
	if (!logPath) return;
	appendFileSync(logPath, `${JSON.stringify({ ts: new Date().toISOString(), ...entry })}\n`);
}

// Request shape only (sizes, settings), never content: lets reports compare what each client sends.
function requestShape(body: ArrayBuffer): Record<string, unknown> {
	if (body.byteLength === 0) return {};
	try {
		const parsed = JSON.parse(new TextDecoder().decode(body));
		const system = typeof parsed.system === "string" ? parsed.system : JSON.stringify(parsed.system ?? "");
		return {
			model: typeof parsed.model === "string" ? parsed.model : undefined,
			request_bytes: body.byteLength,
			system_chars: system.length,
			tools: Array.isArray(parsed.tools) ? parsed.tools.length : 0,
			messages: Array.isArray(parsed.messages) ? parsed.messages.length : 0,
			max_tokens: parsed.max_tokens ?? parsed.max_completion_tokens,
			thinking: parsed.thinking?.type,
			effort: parsed.output_config?.effort ?? parsed.reasoning_effort ?? parsed.thinking?.effort,
		};
	} catch {
		return { request_bytes: body.byteLength };
	}
}

function inboundToken(req: Request): string | undefined {
	const auth = req.headers.get("authorization");
	if (auth?.toLowerCase().startsWith("bearer ")) return auth.slice(7).trim();
	return req.headers.get("x-api-key")?.trim() || undefined;
}

// Token usage as the provider reported it on the wire, identical accounting for every client.
// Handles Anthropic SSE (message_start / message_delta) and OpenAI chat chunks or JSON bodies.
function usageFromText(text: string): Record<string, number> {
	const usage: Record<string, number> = {};
	const merge = (raw: unknown) => {
		if (!raw || typeof raw !== "object") return;
		const record = raw as Record<string, unknown>;
		const details = record.prompt_tokens_details as Record<string, unknown> | undefined;
		const fields: Record<string, unknown> = {
			input_tokens: record.input_tokens ?? record.prompt_tokens,
			output_tokens: record.output_tokens ?? record.completion_tokens,
			cache_read_tokens: record.cache_read_input_tokens ?? details?.cached_tokens,
			cache_write_tokens: record.cache_creation_input_tokens,
		};
		for (const [key, value] of Object.entries(fields)) {
			if (typeof value === "number") usage[key] = Math.max(usage[key] ?? 0, value);
		}
	};
	const documents = text.includes("data:")
		? text.split("\n").filter(line => line.startsWith("data:")).map(line => line.slice(5).trim())
		: [text];
	for (const document of documents) {
		try {
			const event = JSON.parse(document);
			merge(event.usage);
			merge(event.message?.usage);
		} catch {
			// Non-JSON keepalives and [DONE] markers carry no usage.
		}
	}
	return usage;
}

// Pass chunks through untouched while keeping the lines that can carry usage.
// (A tee()'d body crashed Bun when a client disconnected mid-stream.)
function meteredStream(onDone: (usage: Record<string, number>) => void): TransformStream<Uint8Array, Uint8Array> {
	const decoder = new TextDecoder();
	let pending = "";
	let kept = "";
	return new TransformStream({
		transform(chunk, controller) {
			controller.enqueue(chunk);
			pending += decoder.decode(chunk, { stream: true });
			const lines = pending.split("\n");
			pending = lines.pop() ?? "";
			for (const line of lines) if (line.includes("usage")) kept += `${line}\n`;
		},
		flush() {
			kept += pending + decoder.decode();
			onDone(usageFromText(kept));
		},
	});
}

Bun.serve({
	hostname: host,
	port,
	idleTimeout: 0,
	async fetch(req) {
		const url = new URL(req.url);
		if (url.pathname === "/healthz") return Response.json({ ok: true });
		const presented = inboundToken(req);
		const trial = presented ? verifyTrialToken(presented) : undefined;
		if (!trial) return Response.json({ error: { type: "authentication_error", message: "arena token rejected" } }, { status: 401 });
		const route = url.pathname.startsWith("/coding/")
			? { provider: "kimi", credential: "kimi-code", upstream: `${UPSTREAM}${url.pathname}` }
			: url.pathname.startsWith("/zai/")
				? { provider: "zai", credential: "zai", upstream: `${ZAI_UPSTREAM}${url.pathname.slice("/zai".length)}` }
				: undefined;
		if (!route) return Response.json({ error: "unknown path" }, { status: 404 });

		const body = req.method === "GET" || req.method === "HEAD" ? new ArrayBuffer(0) : await req.arrayBuffer();
		const shape = { provider: route.provider, ...requestShape(body) };
		const headers = new Headers(req.headers);
		for (const name of ["authorization", "x-api-key", "host", "content-length", "connection", "accept-encoding"]) headers.delete(name);
		if (route.provider === "kimi" && !headers.has("x-msh-platform")) {
			for (const [name, value] of Object.entries(FALLBACK_FINGERPRINT)) headers.set(name, value);
		}
		const started = Date.now();
		const send = async (force: boolean) => {
			const token = await upstreamToken(route.credential, force);
			headers.set("authorization", `Bearer ${token}`);
			// Z.AI's Anthropic-compatible endpoint (used by omp for GLM) authenticates with x-api-key.
			if (route.provider === "zai") headers.set("x-api-key", token);
			return fetch(`${route.upstream}${url.search}`, {
				method: req.method,
				headers,
				body: body.byteLength ? body : undefined,
				signal: req.signal,
				decompress: true,
			} as RequestInit);
		};
		try {
			let response = await send(false);
			let retried = false;
			if (response.status === 401) {
				await response.body?.cancel();
				response = await send(true);
				retried = true;
			}
			const outHeaders = new Headers(response.headers);
			for (const name of ["content-encoding", "content-length", "transfer-encoding", "connection"]) outHeaders.delete(name);
			// The request record is written at response headers so an aborted stream still counts.
			log({ trial, method: req.method, path: url.pathname, ...shape, status: response.status, retried, ttfb_ms: Date.now() - started });
			if (!response.body) return new Response(null, { status: response.status, headers: outHeaders });
			const body = response.body.pipeThrough(
				meteredStream(usage =>
					log({
						trial,
						kind: "usage",
						path: url.pathname,
						provider: route.provider,
						...usage,
						// The stream carried no usage record; reports fall back to client-reported usage.
						...(Object.keys(usage).length === 0 ? { usage_missing: true } : {}),
						total_ms: Date.now() - started,
					}),
				),
			);
			return new Response(body, { status: response.status, headers: outHeaders });
		} catch (error) {
			const message = error instanceof Error ? error.name : "error";
			log({ trial, method: req.method, path: url.pathname, ...shape, status: 502, error: message, ttfb_ms: Date.now() - started });
			return Response.json({ error: { type: "proxy_error", message: "upstream request failed" } }, { status: 502 });
		}
	},
});

// One trial's broken stream must never take down every other trial's model traffic.
process.on("uncaughtException", error => log({ kind: "proxy_exception", error: error?.name ?? "error" }));
process.on("unhandledRejection", error => log({ kind: "proxy_rejection", error: (error as Error)?.name ?? "error" }));

console.error(`kimi auth proxy listening on ${host}:${port}`);

