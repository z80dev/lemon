/**
 * In-process fake control plane.
 *
 * Speaks the real frame protocol (connect -> hello-ok, req/res correlation,
 * server-pushed events) over a `Bun.serve` WebSocket, so protocol and app tests
 * exercise the same code path as the daemon without spawning BEAM. Scripted
 * responses are per method; every received frame is recorded for assertions.
 */

import type { ServerWebSocket } from "bun";
import type { ProtocolErrorPayload, ReqFrame } from "../protocol/frames.ts";
import { OMP_METHODS } from "../protocol/methods.ts";
import {
	OMP_DISCOVERED_FIXTURES,
	OMP_SESSION_FIXTURES,
	type OmpWire,
} from "./fixtures/omp-fixtures.ts";

/** Return this from a handler to leave the request unanswered (timeout tests). */
export const NO_RESPONSE = Symbol("fake-server:no-response");

interface ErrorResult {
	__fakeError: ProtocolErrorPayload;
}

/** Return this from a handler to answer with `ok: false`. */
export function errorResult(code: string, message: string, details?: unknown): ErrorResult {
	return { __fakeError: { code, message, details } };
}

function isErrorResult(value: unknown): value is ErrorResult {
	return typeof value === "object" && value !== null && "__fakeError" in value;
}

export interface MethodContext {
	socket: ServerWebSocket<SocketData>;
	frame: ReqFrame;
	server: FakeControlPlane;
}

export type MethodHandler = (
	params: any,
	ctx: MethodContext,
) => unknown | Promise<unknown> | typeof NO_RESPONSE;

export interface FakeControlPlaneOptions {
	/** Advertised in `hello-ok.features.methods`. */
	methods?: string[];
	/** Advertised in `hello-ok.features.events`. */
	events?: string[];
	tickIntervalMs?: number;
	protocol?: number;
	serverVersion?: string;
	/** Reject the handshake with this error instead of sending hello-ok. */
	rejectHandshake?: ProtocolErrorPayload;
	/** Port to listen on. 0 (default) picks a free one. */
	port?: number;
}

export interface SocketData {
	connected: boolean;
	id: number;
}

interface RequestWaiter {
	method: string;
	resolve: (frame: ReqFrame) => void;
}

export const DEFAULT_METHODS = [
	"chat.send",
	"chat.abort",
	"chat.history",
	"profiles.list",
	"profiles.get",
	"profiles.create",
	"profiles.clone",
	"profiles.rename",
	"profiles.export",
	"profiles.delete",
	"profiles.roster",
	"profile.chat",
	"sessions.list",
	"sessions.get",
	"sessions.preview",
	"sessions.active",
	"sessions.active.list",
	"sessions.patch",
	"sessions.metadata.patch",
	"sessions.export",
	"sessions.prune",
	"sessions.reset",
	"sessions.delete",
	"sessions.compact",
	"sessions.context",
	"session.detail",
	"commands.catalog",
	"agents.list",
	"background.start",
	"background.list",
	"background.status",
	"background.result",
	"background.cancel",
	"session.btw",
	"models.list",
	"exec.approval.resolve",
	"exec.approvals.get",
	"health",
	"status",
	"usage.status",
	"usage.cost",
	"runs.active.list",
	"runs.recent.list",
	"runs.timeline.get",
	"tasks.active.list",
	"tasks.recent.list",
	"goal.set",
	"goal.status",
	"goal.pause",
	"goal.resume",
	"goal.clear",
	"cron.list",
	"cron.add",
	"cron.update",
	"cron.pause",
	"cron.resume",
	"cron.remove",
	"logs.tail",
	"config.get",
	"config.set",
	"skills.hermes.catalog",
	"skills.install",
	"blueprints.list",
	"blueprints.inspect",
	"blueprints.validate",
	"blueprints.preview",
	"blueprints.activate",
];

export const DEFAULT_EVENTS = ["agent", "chat", "goal", "tick", "presence", "health", "shutdown"];

export class FakeControlPlane {
	readonly received: ReqFrame[] = [];

	#server: ReturnType<typeof Bun.serve> | undefined;
	#sockets = new Set<ServerWebSocket<SocketData>>();
	#handlers = new Map<string, MethodHandler>();
	#options: Required<Omit<FakeControlPlaneOptions, "rejectHandshake" | "port">> & {
		rejectHandshake?: ProtocolErrorPayload;
		port: number;
	};
	#seq = 0;
	#socketSeq = 0;
	#requestWaiters: RequestWaiter[] = [];
	#connectionWaiters: Array<() => void> = [];

	constructor(options: FakeControlPlaneOptions = {}) {
		this.#options = {
			methods: options.methods ?? DEFAULT_METHODS,
			events: options.events ?? DEFAULT_EVENTS,
			tickIntervalMs: options.tickIntervalMs ?? 1000,
			protocol: options.protocol ?? 1,
			serverVersion: options.serverVersion ?? "fake-0.0.0",
			rejectHandshake: options.rejectHandshake,
			port: options.port ?? 0,
		};
	}

	static async start(options: FakeControlPlaneOptions = {}): Promise<FakeControlPlane> {
		const server = new FakeControlPlane(options);
		server.listen();
		return server;
	}

	listen(): this {
		if (this.#server) return this;
		const self = this;
		this.#server = Bun.serve<SocketData>({
			// Match url's IPv4 host instead of Bun's potentially IPv6-only localhost.
			hostname: "127.0.0.1",
			port: this.#options.port,
			fetch(request, server) {
				if (server.upgrade(request, { data: { connected: false, id: 0 } })) return undefined;
				return new Response("fake control plane", { status: 200 });
			},
			websocket: {
				open(socket) {
					socket.data.id = ++self.#socketSeq;
					self.#sockets.add(socket);
					const waiters = self.#connectionWaiters;
					self.#connectionWaiters = [];
					for (const waiter of waiters) waiter();
				},
				message(socket, message) {
					void self.#onMessage(socket, typeof message === "string" ? message : message.toString());
				},
				close(socket) {
					self.#sockets.delete(socket);
				},
			},
		});
		return this;
	}

	get port(): number {
		const port = this.#server?.port;
		if (port === undefined) throw new Error("fake control plane is not listening");
		return port;
	}

	get url(): string {
		return `ws://127.0.0.1:${this.port}/ws`;
	}

	get connectionCount(): number {
		return this.#sockets.size;
	}

	get advertisedMethods(): string[] {
		return [...this.#options.methods];
	}

	/** Script a method. The handler's return value becomes the `res` payload. */
	onMethod(method: string, handler: MethodHandler | unknown): this {
		this.#handlers.set(
			method,
			typeof handler === "function" ? (handler as MethodHandler) : () => handler,
		);
		return this;
	}

	/** Answer `method` with a fixed payload. */
	respondWith(method: string, payload: unknown): this {
		return this.onMethod(method, () => payload);
	}

	/** Answer `method` with `ok: false`. */
	failWith(method: string, code: string, message: string, details?: unknown): this {
		return this.onMethod(method, () => errorResult(code, message, details));
	}

	/** Never answer `method` — used to exercise request timeouts. */
	silenceMethod(method: string): this {
		return this.onMethod(method, () => NO_RESPONSE);
	}

	/**
	 * Script `sessions.context` with wire receipts by session key (see
	 * `fixtures/context-fixtures.ts`). Any other session answers NOT_FOUND, as a
	 * session without durable history does on the real daemon.
	 */
	serveSessionContext(receipts: Readonly<Record<string, unknown>>): this {
		return this.onMethod("sessions.context", (params: { sessionKey?: string }) => {
			const key = params?.sessionKey;
			if (typeof key === "string" && Object.hasOwn(receipts, key)) return receipts[key];
			return errorResult("NOT_FOUND", "session not found");
		});
	}

	/** Push an event frame to every connected socket. */
	pushEvent(event: string, payload?: unknown, stateVersion?: Record<string, number>): number {
		const seq = ++this.#seq;
		const frame: Record<string, unknown> = { type: "event", event, seq };
		if (payload !== undefined) frame.payload = payload;
		if (stateVersion) frame.stateVersion = stateVersion;
		this.broadcast(JSON.stringify(frame));
		return seq;
	}

	/** Push arbitrary text (malformed-frame tests). */
	broadcast(text: string): void {
		for (const socket of this.#sockets) socket.send(text);
	}

	requestsFor(method: string): ReqFrame[] {
		return this.received.filter((frame) => frame.method === method);
	}

	waitForRequest(method: string, timeoutMs = 2000): Promise<ReqFrame> {
		const existing = this.requestsFor(method);
		if (existing.length > 0) return Promise.resolve(existing[existing.length - 1]);
		return new Promise((resolve, reject) => {
			const waiter = { method, resolve };
			this.#requestWaiters.push(waiter);
			const timer = setTimeout(() => {
				const index = this.#requestWaiters.indexOf(waiter);
				if (index >= 0) this.#requestWaiters.splice(index, 1);
				reject(new Error(`no "${method}" request within ${timeoutMs}ms`));
			}, timeoutMs);
			timer.unref?.();
		});
	}

	waitForConnection(timeoutMs = 2000): Promise<void> {
		if (this.#sockets.size > 0) return Promise.resolve();
		return new Promise((resolve, reject) => {
			const waiter = () => resolve();
			this.#connectionWaiters.push(waiter);
			const timer = setTimeout(() => {
				const index = this.#connectionWaiters.indexOf(waiter);
				if (index >= 0) this.#connectionWaiters.splice(index, 1);
				reject(new Error(`no connection within ${timeoutMs}ms`));
			}, timeoutMs);
			timer.unref?.();
		});
	}

	/** Drop every live connection without stopping the listener. */
	dropConnections(code = 1006, reason = "dropped"): void {
		for (const socket of [...this.#sockets]) {
			this.#sockets.delete(socket);
			try {
				if (code === 1006) socket.terminate();
				else socket.close(code, reason);
			} catch {
				// Socket already gone.
			}
		}
	}

	clearReceived(): void {
		this.received.length = 0;
	}

	stop(): void {
		this.dropConnections();
		this.#server?.stop(true);
		this.#server = undefined;
	}

	// -- internals ----------------------------------------------------------

	async #onMessage(socket: ServerWebSocket<SocketData>, raw: string): Promise<void> {
		let frame: ReqFrame;
		try {
			frame = JSON.parse(raw) as ReqFrame;
		} catch {
			return;
		}
		if (frame?.type !== "req" || typeof frame.id !== "string") return;
		this.received.push(frame);
		this.#notifyRequestWaiters(frame);

		if (frame.method === "connect") {
			this.#handleConnect(socket, frame);
			return;
		}
		if (!socket.data.connected) {
			this.#sendError(socket, frame.id, {
				code: "HANDSHAKE_REQUIRED",
				message: "Must complete handshake first",
			});
			return;
		}

		const handler = this.#handlers.get(frame.method);
		if (!handler) {
			this.#sendError(socket, frame.id, {
				code: "METHOD_NOT_FOUND",
				message: `Unknown method: ${frame.method}`,
			});
			return;
		}

		let result: unknown;
		try {
			result = await handler(frame.params, { socket, frame, server: this });
		} catch (error) {
			this.#sendError(socket, frame.id, {
				code: "INTERNAL_ERROR",
				message: error instanceof Error ? error.message : String(error),
			});
			return;
		}
		if (result === NO_RESPONSE) return;
		if (isErrorResult(result)) {
			this.#sendError(socket, frame.id, result.__fakeError);
			return;
		}
		this.#send(socket, { type: "res", id: frame.id, ok: true, payload: result ?? {} });
	}

	#handleConnect(socket: ServerWebSocket<SocketData>, frame: ReqFrame): void {
		const reject = this.#options.rejectHandshake;
		if (reject) {
			this.#sendError(socket, frame.id, reject);
			return;
		}
		socket.data.connected = true;
		// The real server answers `connect` with hello-ok and no res frame.
		this.#send(socket, {
			type: "hello-ok",
			protocol: this.#options.protocol,
			server: {
				version: this.#options.serverVersion,
				commit: "deadbeef",
				host: "fake",
				connId: `conn-${socket.data.id}`,
			},
			features: { methods: this.#options.methods, events: this.#options.events },
			snapshot: { presence: {}, health: { ok: true } },
			policy: {
				maxPayload: 1_048_576,
				maxBufferedBytes: 8_388_608,
				tickIntervalMs: this.#options.tickIntervalMs,
			},
			auth: { role: "operator", scopes: ["read", "write", "admin"] },
		});
	}

	#notifyRequestWaiters(frame: ReqFrame): void {
		if (this.#requestWaiters.length === 0) return;
		const remaining: RequestWaiter[] = [];
		for (const waiter of this.#requestWaiters) {
			if (waiter.method === frame.method) waiter.resolve(frame);
			else remaining.push(waiter);
		}
		this.#requestWaiters = remaining;
	}

	#send(socket: ServerWebSocket<SocketData>, frame: unknown): void {
		socket.send(JSON.stringify(frame));
	}

	#sendError(socket: ServerWebSocket<SocketData>, id: string, error: ProtocolErrorPayload): void {
		this.#send(socket, { type: "res", id, ok: false, error });
	}
}

/** Default methods plus the omp delegate surface; pass as `methods` to advertise it. */
export const OMP_FAKE_METHODS: readonly string[] = [...DEFAULT_METHODS, ...OMP_METHODS];
/** Default events plus `omp.session`. */
export const OMP_FAKE_EVENTS: readonly string[] = [...DEFAULT_EVENTS, "omp.session"];

export interface OmpFakeOptions {
	/** `omp.status.available`; false makes start/resume answer UNAVAILABLE. */
	available?: boolean;
	sessions?: readonly OmpWire[];
	discovered?: readonly OmpWire[];
}

export interface OmpFake {
	readonly sessions: Map<string, OmpWire>;
	/** Change one session and push the matching `omp.session` event. */
	update(id: string, patch: OmpWire, reason?: string): OmpWire;
}

/**
 * Script every `omp.*` method against an in-memory set of delegate sessions
 * (seeded from the recorded fixtures) and push `omp.session` events as they
 * change, so the panel, `/omp` and the status badge can run offline:
 * `FakeControlPlane.start({ methods: [...OMP_FAKE_METHODS], events: [...OMP_FAKE_EVENTS] })`.
 */
export function installOmpFixtures(
	server: FakeControlPlane,
	options: OmpFakeOptions = {},
): OmpFake {
	const available = options.available ?? true;
	const sessions = new Map<string, OmpWire>();
	for (const wire of options.sessions ?? OMP_SESSION_FIXTURES)
		sessions.set(String(wire.id), { ...wire });
	const discovered = options.discovered ?? OMP_DISCOVERED_FIXTURES;
	let seq = 0;
	const ended = (wire: OmpWire) => wire.status === "closed" || wire.status === "failed";
	const update = (id: string, patch: OmpWire, reason = "updated") => {
		const next = { ...sessions.get(id), ...patch, updatedAt: Date.now() };
		sessions.set(id, next);
		server.pushEvent("omp.session", { reason, session: next });
		return next;
	};
	const launch = (
		params: { prompt?: string; cwd?: string },
		ompSessionId: string,
		title: string,
	) => {
		const id = `omp_fake${String(++seq).padStart(6, "0")}`;
		const now = Date.now();
		const wire: OmpWire = {
			...OMP_SESSION_FIXTURES[0],
			id,
			ompSessionId,
			title,
			cwd: params.cwd ?? null,
			status: "running",
			lastTurn: null,
			activity: "Thinking",
			startedAt: now,
			updatedAt: now,
			turns: 0,
			toolCalls: 0,
			activeTools: [],
			recentTools: [],
			todos: [],
			subagents: [],
			usage: null,
			contextPercent: null,
			lastText: null,
			result: null,
			error: null,
		};
		sessions.set(id, wire);
		server.pushEvent("omp.session", { reason: "started", session: wire });
		return { session: wire };
	};
	const find = (id: unknown) => (typeof id === "string" ? sessions.get(id) : undefined);
	const notFound = (id: unknown) => errorResult("NOT_FOUND", `omp session ${String(id)} not found`);

	server
		.onMethod("omp.status", () => ({
			available,
			version: available ? "14.2.0" : null,
			reason: available ? null : "not_installed",
			live: [...sessions.values()].filter((wire) => !ended(wire)).length,
			maxSessions: 8,
		}))
		.onMethod("omp.sessions.list", (params: { includeEnded?: boolean; limit?: number } = {}) => ({
			sessions: [...sessions.values()]
				.filter((wire) => params.includeEnded !== false || !ended(wire))
				.slice(0, params.limit ?? 50),
		}))
		.onMethod("omp.sessions.get", (params: { id?: string }) => {
			const wire = find(params?.id);
			return wire
				? { session: wire, summary: `omp ${wire.id}: ${wire.status}` }
				: notFound(params?.id);
		})
		.onMethod("omp.sessions.discover", (params: { cwd?: string }) =>
			params?.cwd ? { sessions: discovered } : errorResult("INVALID_PARAMS", "cwd is required"),
		)
		.onMethod("omp.sessions.start", (params: { prompt?: string; cwd?: string }) => {
			if (!available) return errorResult("UNAVAILABLE", "omp is not installed");
			if (!params?.prompt) return errorResult("INVALID_PARAMS", "prompt is required");
			return launch(params, crypto.randomUUID(), params.prompt.split("\n")[0]!.slice(0, 120));
		})
		.onMethod("omp.sessions.resume", (params: { ompSessionId?: string; cwd?: string }) => {
			if (!available) return errorResult("UNAVAILABLE", "omp is not installed");
			const row = discovered.find((entry) => entry.ompSessionId === params?.ompSessionId);
			if (!row) return notFound(params?.ompSessionId);
			return launch(params, String(row.ompSessionId), String(row.title ?? ""));
		})
		.onMethod("omp.sessions.send", (params: { id?: string; message?: string; mode?: string }) => {
			const wire = find(params?.id);
			if (!wire) return notFound(params?.id);
			if (ended(wire)) return errorResult("CONFLICT", "omp session is not running");
			const delivery = wire.status === "idle" ? "prompt" : (params.mode ?? "steer");
			update(String(wire.id), { status: "running", activity: "Thinking", lastTurn: null });
			return { accepted: true, delivery };
		})
		.onMethod("omp.sessions.cancel", (params: { id?: string }) => {
			const wire = find(params?.id);
			if (!wire) return notFound(params?.id);
			if (wire.status !== "running") return errorResult("CONFLICT", "no active turn");
			update(
				String(wire.id),
				{ status: "idle", lastTurn: "aborted", activity: null, activeTools: [] },
				"settled",
			);
			return { cancelled: true };
		})
		.onMethod("omp.sessions.close", (params: { id?: string }) => {
			const wire = find(params?.id);
			if (!wire) return notFound(params?.id);
			const now = Date.now();
			const closed = update(
				String(wire.id),
				{
					status: "closed",
					activity: null,
					activeTools: [],
					endedAt: now,
					exit: { code: 0, reason: "closed" },
				},
				"exited",
			);
			return { session: closed };
		});
	return { sessions, update };
}
