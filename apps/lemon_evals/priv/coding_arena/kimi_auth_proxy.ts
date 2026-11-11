/**
 * Host-side Kimi Code auth proxy for isolated arena trials.
 *
 * Trial containers never hold a real credential. Each trial receives an
 * HS256-signed JWT whose `sub` is its trial id; the proxy verifies it, swaps it
 * for the operator's Kimi Code OAuth access token (obtained from `omp token
 * kimi-code`, so omp alone owns refresh-token rotation), and streams the
 * upstream response back unchanged. Every request is attributed to its trial in
 * a JSONL log (model, status, latency) without prompts, bodies or tokens.
 *
 *   ARENA_PROXY_SECRET=... bun kimi_auth_proxy.ts --port 18787 --log /path/requests.jsonl
 */
import { appendFileSync } from "node:fs";
import { createHmac, timingSafeEqual } from "node:crypto";

const UPSTREAM = process.env.KIMI_UPSTREAM ?? "https://api.kimi.com";
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

let cached: { token: string; expiresMs: number } | undefined;
let inflight: Promise<string> | undefined;

async function fetchUpstreamToken(force: boolean): Promise<string> {
	const argv = [ompBin, "token", "kimi-code", ...(force ? ["--force-refresh"] : [])];
	const proc = Bun.spawn(argv, { stdout: "pipe", stderr: "pipe", stdin: "ignore" });
	const [stdout, code] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
	const token = stdout.trim();
	if (code !== 0 || !token) throw new Error(`omp token kimi-code failed (exit ${code})`);
	cached = { token, expiresMs: jwtExpiryMs(token) };
	return token;
}

async function upstreamToken(force = false): Promise<string> {
	if (!force && cached && cached.expiresMs - REFRESH_MARGIN_MS > Date.now()) return cached.token;
	inflight ??= fetchUpstreamToken(force).finally(() => {
		inflight = undefined;
	});
	return inflight;
}

function log(entry: Record<string, unknown>) {
	if (!logPath) return;
	appendFileSync(logPath, `${JSON.stringify({ ts: new Date().toISOString(), ...entry })}\n`);
}

function requestModel(body: ArrayBuffer): string | undefined {
	if (body.byteLength === 0) return undefined;
	try {
		const parsed = JSON.parse(new TextDecoder().decode(body));
		return typeof parsed.model === "string" ? parsed.model : undefined;
	} catch {
		return undefined;
	}
}

function inboundToken(req: Request): string | undefined {
	const auth = req.headers.get("authorization");
	if (auth?.toLowerCase().startsWith("bearer ")) return auth.slice(7).trim();
	return req.headers.get("x-api-key")?.trim() || undefined;
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
		if (!url.pathname.startsWith("/coding/")) return Response.json({ error: "unknown path" }, { status: 404 });

		const body = req.method === "GET" || req.method === "HEAD" ? new ArrayBuffer(0) : await req.arrayBuffer();
		const model = requestModel(body);
		const headers = new Headers(req.headers);
		for (const name of ["authorization", "x-api-key", "host", "content-length", "connection", "accept-encoding"]) headers.delete(name);
		if (!headers.has("x-msh-platform")) {
			for (const [name, value] of Object.entries(FALLBACK_FINGERPRINT)) headers.set(name, value);
		}
		const started = Date.now();
		const send = async (force: boolean) => {
			headers.set("authorization", `Bearer ${await upstreamToken(force)}`);
			return fetch(`${UPSTREAM}${url.pathname}${url.search}`, {
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
			log({ trial, method: req.method, path: url.pathname, model, status: response.status, retried, ttfb_ms: Date.now() - started });
			const outHeaders = new Headers(response.headers);
			for (const name of ["content-encoding", "content-length", "transfer-encoding", "connection"]) outHeaders.delete(name);
			return new Response(response.body, { status: response.status, headers: outHeaders });
		} catch (error) {
			const message = error instanceof Error ? error.name : "error";
			log({ trial, method: req.method, path: url.pathname, model, status: 502, error: message, ttfb_ms: Date.now() - started });
			return Response.json({ error: { type: "proxy_error", message: "upstream request failed" } }, { status: 502 });
		}
	},
});

console.error(`kimi auth proxy listening on ${host}:${port}`);

