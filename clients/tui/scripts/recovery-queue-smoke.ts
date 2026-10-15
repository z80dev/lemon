/**
 * Prepared, not executed by the author. Run from clients/tui in a real terminal:
 *   bun run scripts/recovery-queue-smoke.ts
 * Requires centrally prepared dev BEAM artifacts and installed TUI dependencies.
 * No build, ExUnit, fake control plane, provider credentials, or provider network.
 * The local SSE fixture pauses real native runs admitted by the production router.
 */
import { chmod, mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { AppShell } from "../src/app.ts";
import { pick, pickString } from "../src/commands/format.ts";
import { ControlPlaneClient, type RequestOptions } from "../src/protocol/client.ts";
import { initTheme } from "../src/ui/theme/theme.ts";

function check(condition: unknown, message: string): void {
	if (!condition) throw new Error(message);
}

function deferred() {
	let resolve!: () => void;
	const promise = new Promise<void>((done) => {
		resolve = done;
	});
	return { promise, resolve };
}

async function until(
	predicate: () => boolean | Promise<boolean>,
	description: string,
	timeout = 30_000,
) {
	const deadline = Date.now() + timeout;
	while (!(await predicate())) {
		check(Date.now() < deadline, `deadline: ${description}`);
		await Bun.sleep(25);
	}
}

// Observation only: every request and receipt still uses the production client,
// real WebSocket, authenticated handler and accepting router. No result is replaced.
class ObservedClient extends ControlPlaneClient {
	readonly sends: Array<{ prompt: string | undefined; runId?: string }> = [];
	readonly snapshots: unknown[] = [];
	override async request<T = unknown>(
		method: string,
		params?: unknown,
		options?: RequestOptions,
	): Promise<T> {
		const observation: { prompt: string | undefined; runId?: string } | undefined =
			method === "chat.send" ? { prompt: pickString(params, "prompt") } : undefined;
		if (observation) this.sends.push(observation);
		const receipt = await super.request<T>(method, params, options);
		if (observation) observation.runId = pickString(receipt, "runId");
		if (method === "sessions.snapshot" && pick(receipt, "status") === "ok")
			this.snapshots.push(receipt);
		return receipt;
	}
}

check(
	process.stdin.isTTY && process.stdout.isTTY,
	"run this public AppShell smoke in a PTY/terminal",
);
const backgroundMode = process.argv.includes("--background");
const repo = resolve(import.meta.dir, "../../..");
const root = await mkdtemp(resolve(tmpdir(), "lemon-recovery-queue-"));
await chmod(root, 0o700);
for (const name of ["home/.lemon", "workspace", "agent", "store", "dotenv"])
	await mkdir(resolve(root, name), { recursive: true });
const credential = crypto.randomUUID() + crypto.randomUUID();
const credentialFile = resolve(root, "operator.token");
await writeFile(credentialFile, `${credential}\n`, { mode: 0o400 });
const gates = [deferred(), deferred()];
const bodies: unknown[] = [];
let auxiliaryFactRequests = 0;
const answer = "Canonical real-owner recovery queue smoke answer.";
let fixtureFailure: string | undefined;
const provider = Bun.serve({
	hostname: "127.0.0.1",
	port: 0,
	async fetch(request) {
		if (new URL(request.url).pathname !== "/v1/responses" || request.method !== "POST")
			return new Response("not found", { status: 404 });
		if (request.headers.get("authorization") !== "Bearer isolated-recovery-provider-key")
			return new Response("fixture credential required", { status: 403 });
		const body = await request.json();
		const input = pick(body, "input");
		const projectFacts =
			Array.isArray(input) &&
			input.some(
				(row: unknown) =>
					pick(row, "role") === "system" &&
					pickString(row, "content")?.startsWith("Extract durable repository facts"),
			);
		if (projectFacts) auxiliaryFactRequests += 1;
		else {
			const index = bodies.length;
			bodies.push(body);
			if (index >= gates.length) {
				fixtureFailure = "unexpected third native provider invocation";
				return new Response("unexpected invocation", { status: 500 });
			}
			await gates[index].promise;
		}
		const events = [
			{ type: "response.output_item.added", item: { type: "message" } },
			{ type: "response.output_text.delta", delta: projectFacts ? "[]" : answer },
			{
				type: "response.completed",
				response: {
					status: "completed",
					usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 },
				},
			},
		];
		return new Response(
			`${events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("")}data: [DONE]\n\n`,
			{ headers: { "content-type": "text/event-stream", "cache-control": "no-cache" } },
		);
	},
});
const reservations = Array.from({ length: 3 }, () =>
	Bun.serve({
		hostname: "127.0.0.1",
		port: 0,
		fetch: () => new Response("reserved", { status: 503 }),
	}),
);
const [controlPort, webPort, simPort] = reservations.map((server) => server.port);
check(controlPort && webPort && simPort, "could not reserve isolated runtime ports");
const url = `ws://127.0.0.1:${controlPort}/ws`;
const sessionKey = `agent:default:tui:main:unknown:recovery-queue-${crypto.randomUUID()}`;
const config = `[defaults]\nprovider = "openai"\nmodel = "gpt-4o-mini"\n\n[providers.openai]\nbase_url = "http://127.0.0.1:${provider.port}/v1"\napi_key_secret = "OPENAI_API_KEY"\n\n[gateway]\nmax_concurrent_runs = 1\nauto_resume = false\nenable_telegram = false\n\n[features]\nrouting_feedback = "opt-in"\nskill_synthesis_drafts = "opt-in"\n`;
await writeFile(resolve(root, "home/.lemon/config.toml"), config, { mode: 0o600 });
const env: Record<string, string> = {};
const nodeName = `recovery_queue_${process.pid}`;
const nodeCookie = crypto.randomUUID().replaceAll("-", "");
// Allowlist the host build-tool paths, never ambient API/channel credentials.
for (const name of ["PATH", "TMPDIR", "LANG", "LC_ALL", "ASDF_DATA_DIR"]) {
	const value = process.env[name];
	if (value) env[name] = value;
}
Object.assign(env, {
	MIX_ENV: "dev",
	MIX_HOME: process.env.MIX_HOME ?? resolve(process.env.HOME ?? "", ".mix"),
	HEX_HOME: process.env.HEX_HOME ?? resolve(process.env.HOME ?? "", ".hex"),
	HOME: resolve(root, "home"),
	LEMON_AGENT_DIR: resolve(root, "agent"),
	LEMON_LOCK_DIR: resolve(root, "locks"),
	LEMON_STORE_PATH: resolve(root, "store"),
	LEMON_DOTENV_DIR: resolve(root, "dotenv"),
	LEMON_CONTROL_PLANE_PORT: String(controlPort),
	LEMON_WEB_PORT: String(webPort),
	LEMON_SIM_UI_PORT: String(simPort),
	LEMON_GATEWAY_HEALTH_PORT: "0",
	LEMON_ROUTER_HEALTH_PORT: "0",
	LEMON_CONTROL_PLANE_OPERATOR_TOKEN: credential,
	LEMON_GATEWAY_NODE_NAME: nodeName,
	LEMON_GATEWAY_NODE_COOKIE: nodeCookie,
	ERL_FLAGS: "+S 4:4",
	LEMON_CONTROL_PLANE_ALLOW_UNAUTHENTICATED_LOOPBACK: "false",
	LEMON_HONCHO_ENABLED: "false",
	LEMON_SECRETS_MASTER_KEY: Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString(
		"base64",
	),
	LEMON_WEB_SECRET_KEY_BASE: crypto.randomUUID().repeat(3),
	OPENAI_API_KEY: "isolated-recovery-provider-key",
	PHX_SERVER: "1",
});
for (const server of reservations) server.stop(true);
const runtime = Bun.spawn(
	[
		"elixir",
		"--sname",
		nodeName,
		"--cookie",
		nodeCookie,
		"-S",
		"mix",
		"run",
		"--no-start",
		"--no-halt",
		"--no-compile",
		"--no-deps-check",
		"-e",
		"LemonCore.Runtime.Boot.start!(:runtime_full)",
	],
	{
		cwd: repo,
		env,
		stdout: Bun.file(resolve(root, "runtime.out.log")),
		stderr: Bun.file(resolve(root, "runtime.err.log")),
	},
);
let app: AppShell | undefined;
try {
	await writeFile(
		resolve(root, "runtime.json"),
		JSON.stringify(
			{
				control_plane_url: url,
				session_key: sessionKey,
				credential_file: credentialFile,
				root,
				source_boundary:
					"actual AppShell + authenticated control plane + router/gateway/native Session; loopback scripted SSE only",
			},
			null,
			2,
		),
		{ mode: 0o400 },
	);
	await until(
		async () => {
			check(runtime.exitCode === null, "runtime exited; inspect private runtime logs");
			try {
				return (await fetch(`http://127.0.0.1:${controlPort}/healthz`)).ok;
			} catch {
				return false;
			}
		},
		"production runtime health",
		90_000,
	);
	initTheme({ colorLevel: 3 });
	const client = new ObservedClient({
		url,
		token: credential,
		socketOptions: { minBackoffMs: 100, maxBackoffMs: 200, jitter: 0 },
	});
	app = new AppShell({
		url,
		sessionKey,
		client,
		cwd: resolve(root, "workspace"),
		smoothStreaming: false,
		readBranch: async () => null,
	});
	const shell = app;
	await shell.start();
	const owner = shell.store.session(sessionKey);
	await shell.submit("first real native smoke turn");
	check(
		client.sends[0]?.runId,
		`first send was not admitted: ${JSON.stringify(client.sends)}; ${shell.chatContainer.render(100).join("\n")}`,
	);
	await until(() => bodies.length === 1, "first router-admitted native invocation");
	await until(async () => {
		await shell.sessions.resync();
		return (
			shell.store.focused.snapshotIdentity?.runId === client.sends[0]?.runId &&
			shell.store.focused.busy
		);
	}, "real running native owner projection");
	const initial = shell.store.focused.snapshotIdentity;
	if (!initial?.runId || !shell.store.focused.busy)
		throw new Error("owner must verify the real first running run");
	check(
		client.sends[0]?.runId === initial.runId,
		"first real router receipt must match the owner run",
	);
	check(
		JSON.stringify(bodies[0]).includes("first real native smoke turn"),
		"first actual provider body must contain the admitted prompt",
	);
	await shell.submit("known-unsent local smoke followup");
	await shell.submit("must wait for the followup native run");
	check(
		shell.store.queue.items(sessionKey).length === 2 &&
			shell.store.queue.items(sessionKey).every((item) => item.state === "queued-local"),
		"followups must remain known-unsent",
	);
	check(client.sends.length === 1, "busy followups must not have reached chat.send");
	const backgroundKey = `agent:default:tui:main:unknown:background-draft-${crypto.randomUUID()}`;
	if (backgroundMode) {
		await shell.sessions.create(backgroundKey);
		shell.host.setDraft("preserved background-focus draft");
	}

	const offline = client.events.waitFor("state", 10_000);
	const reconnected = client.events.waitFor("resync-needed");
	client.reconnect("isolated queue recovery smoke");
	await offline;
	gates[0].resolve();
	await reconnected;
	await until(
		async () => {
			await shell.sessions.resync();
			return client.sends.length === 2 && Boolean(client.sends[1]?.runId) && bodies.length === 2;
		},
		"canonical recovery and one genuinely accepted followup",
		45_000,
	);
	const nextRunId = client.sends[1].runId;
	check(
		nextRunId && nextRunId !== initial.runId,
		"followup needs its own real nonempty router run receipt",
	);
	check(client.sends[1].prompt === "known-unsent local smoke followup", "wrong queue head sent");
	for (let repeat = 0; repeat < 3; repeat++) await shell.sessions.resync();
	check(
		client.sends.length === 2 && bodies.length === 2 && !fixtureFailure,
		"repeated owner reads must not send a third turn",
	);
	const secondBody = JSON.stringify(bodies[1]);
	check(
		secondBody.includes("known-unsent local smoke followup") &&
			!secondBody.includes("must wait for the followup native run"),
		"second actual provider body must contain only the released followup",
	);
	check(owner.busy && owner.activeRunId === nextRunId, "newer native run must stay active");
	check(
		shell.store.queue.items(sessionKey).length === 1 &&
			shell.store.queue.items(sessionKey)[0].text === "must wait for the followup native run",
		"exactly one head may leave the queue",
	);
	const terminalProof = client.snapshots.find(
		(snapshot) =>
			pick(snapshot, "identity.runId") === initial.runId &&
			pick(snapshot, "continuation") === true &&
			pick(snapshot, "snapshot.terminal") === true &&
			pick(snapshot, "snapshot.answer.canonical") === true &&
			pick(snapshot, "snapshot.answer.text") === answer,
	);
	check(terminalProof, "a real canonical terminal continuation must have authorized the followup");
	check(
		owner.blocks.some(
			(block) => block.kind === "assistant" && block.text === answer && block.status === "done",
		),
		"canonical terminal answer must be visibly finalized",
	);
	if (backgroundMode) {
		check(
			shell.store.focusedKey === backgroundKey &&
				shell.host.getDraft() === "preserved background-focus draft",
			"background completion must preserve foreground selection and draft",
		);
		await shell.sessions.switch(sessionKey);
	}
	await writeFile(
		resolve(root, "terminal.ansi"),
		`${shell.chatContainer.render(100).join("\n")}\n\n${shell.queueContainer.render(100).join("\n")}\n`,
		{ mode: 0o600 },
	);
	await writeFile(
		resolve(root, "evidence.json"),
		JSON.stringify(
			{
				status: "passed",
				router_receipts: client.sends.map((send) => send.runId),
				actual_chat_send_requests: client.sends.length,
				native_provider_requests: bodies.length,
				auxiliary_project_fact_requests: auxiliaryFactRequests,
				background_completion: backgroundMode,
				queued_local_remaining: shell.store.queue.items(sessionKey).length,
				first_terminal: "done",
				first_answer: answer,
				initial_identity: initial,
				terminal_identity: pick(terminalProof, "identity"),
				active_run_id: nextRunId,
				terminal_capture: resolve(root, "terminal.ansi"),
				external_provider_execution: false,
			},
			null,
			2,
		),
		{ mode: 0o600 },
	);
	shell.stop();
	app = undefined;
	console.log(
		JSON.stringify({
			status: "passed",
			evidence_file: resolve(root, "evidence.json"),
			runtime_file: resolve(root, "runtime.json"),
			note: "No external provider execution. Private artifacts retained; runtime stopped.",
		}),
	);
} catch (error) {
	await writeFile(resolve(root, "failed-provider-bodies.json"), JSON.stringify(bodies, null, 2), {
		mode: 0o600,
	});
	await writeFile(
		resolve(root, "failed-owner-projections.json"),
		JSON.stringify((app?.client as ObservedClient | undefined)?.snapshots ?? [], null, 2),
		{ mode: 0o600 },
	);
	app?.stop();
	app = undefined;
	console.error(
		JSON.stringify({
			status: "failed",
			root,
			error: error instanceof Error ? error.message : "smoke failure",
			note: "No passing execution evidence claimed; inspect private logs.",
		}),
	);
	process.exitCode = 1;
} finally {
	app?.stop();
	for (const gate of gates) gate.resolve();
	provider.stop(true);
	if (runtime.exitCode === null) runtime.kill("SIGTERM");
	await runtime.exited;
}
