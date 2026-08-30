/**
 * Control-plane client: handshake, request/response correlation, event demux.
 *
 * Connection lifecycle
 * --------------------
 *   socket open -> send `connect` (role: operator, no token for a local
 *   operator, which grants all scopes) -> server replies with a `hello-ok`
 *   frame *instead of* a `res` -> state becomes "online" and every other method
 *   is allowed. Anything sent before that is rejected server-side with
 *   HANDSHAKE_REQUIRED, so the client enforces the same rule locally.
 *
 * Offline behaviour
 * -----------------
 *   `chat.send` issued while not online is parked (the UI is told via the
 *   `queued` event) and flushed FIFO once the handshake completes — typing
 *   before the daemon is ready is a normal thing to do. Every other method
 *   rejects with NotConnectedError rather than silently buffering state-changing
 *   calls across a reconnect.
 */

import { Emitter } from "../store/events.ts";
import {
	ControlPlaneError,
	HandshakeError,
	NotConnectedError,
	RequestTimeoutError,
} from "./errors.ts";
import {
	type EventFrame,
	encodeFrame,
	type HelloOkFrame,
	isEventFrame,
	isHelloOkFrame,
	isResFrame,
	makeReq,
	type ResFrame,
	tryDecodeFrame,
} from "./frames.ts";
import type {
	ClientEventMap,
	ConnectionState,
	ConnectParams,
	ProtocolEventMap,
	ProtocolEventName,
} from "./types.ts";
import { ReconnectingSocket, type ReconnectingSocketOptions } from "./ws.ts";

export const DEFAULT_REQUEST_TIMEOUT_MS = 15_000;
export const DEFAULT_WS_URL = "ws://127.0.0.1:4040/ws";

/** Methods held rather than rejected while offline. */
export const DEFAULT_QUEUEABLE_METHODS: readonly string[] = ["chat.send"];

/** Cheap reads used to prove a quiet connection is still alive, in order. */
const LIVENESS_PROBE_METHODS = ["health", "status"] as const;

export interface RequestOptions {
	/** Overrides the client default (15s). */
	timeoutMs?: number;
	/** Force-allow (or forbid) parking this call while offline. */
	queueIfOffline?: boolean;
	/** Bypass the offline gate — used internally for `connect`. */
	allowWhileConnecting?: boolean;
}

export interface ControlPlaneClientOptions {
	url?: string;
	/** Client identity reported in the handshake. */
	clientId?: string;
	role?: string;
	/** Optional operator token, sent inside the control-plane `auth` envelope. */
	token?: string;
	requestTimeoutMs?: number;
	queueableMethods?: Iterable<string>;
	/** Transport injection point (tests supply a preconfigured socket). */
	socket?: ReconnectingSocket;
	socketOptions?: Omit<ReconnectingSocketOptions, "url">;
}

interface PendingRequest {
	id: string;
	method: string;
	resolve: (value: any) => void;
	reject: (error: unknown) => void;
	timer: ReturnType<typeof setTimeout> | undefined;
}

interface QueuedRequest {
	id: string;
	method: string;
	params: unknown;
	timeoutMs: number;
	resolve: (value: any) => void;
	reject: (error: unknown) => void;
}

export interface QueuedRequestView {
	id: string;
	method: string;
	params: unknown;
}

/** Default client id: stable per host+process, matches `lemon-tui@<host>-<pid>`. */
export function defaultClientId(): string {
	const host = process.env.HOSTNAME || "local";
	return `lemon-tui@${host}-${process.pid}`;
}

export class ControlPlaneClient {
	readonly events = new Emitter<ClientEventMap>();

	readonly #socket: ReconnectingSocket;
	readonly #ownsSocket: boolean;
	readonly #clientId: string;
	readonly #role: string;
	readonly #token: string | undefined;
	readonly #requestTimeoutMs: number;
	readonly #queueableMethods: Set<string>;

	readonly #pending = new Map<string, PendingRequest>();
	readonly #queue: QueuedRequest[] = [];

	#state: ConnectionState = "offline";
	#helloOk: HelloOkFrame | undefined;
	#methods = new Set<string>();
	#handshakeCount = 0;
	#handshakeId: string | undefined;
	#handshakeWaiters: Array<{
		resolve: (hello: HelloOkFrame) => void;
		reject: (error: unknown) => void;
	}> = [];
	#closed = false;
	#probeInFlight = false;
	/** One-line summaries of recent traffic, oldest first (see `/debug`). */
	readonly #frameLog: string[] = [];
	#frameLogLimit = 200;

	constructor(options: ControlPlaneClientOptions = {}) {
		const url = options.url ?? DEFAULT_WS_URL;
		this.#ownsSocket = options.socket === undefined;
		this.#socket = options.socket ?? new ReconnectingSocket({ url, ...options.socketOptions });
		this.#clientId = options.clientId ?? defaultClientId();
		this.#role = options.role ?? "operator";
		this.#token = options.token;
		this.#requestTimeoutMs = options.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;
		this.#queueableMethods = new Set(options.queueableMethods ?? DEFAULT_QUEUEABLE_METHODS);
		this.#wireSocket();
	}

	// -- public surface -----------------------------------------------------

	get url(): string {
		return this.#socket.url;
	}

	get state(): ConnectionState {
		return this.#state;
	}

	get online(): boolean {
		return this.#state === "online";
	}

	get helloOk(): HelloOkFrame | undefined {
		return this.#helloOk;
	}

	get serverMethods(): ReadonlySet<string> {
		return this.#methods;
	}

	get clientId(): string {
		return this.#clientId;
	}

	/** Requests parked while offline, oldest first. */
	get queued(): QueuedRequestView[] {
		return this.#queue.map((entry) => ({
			id: entry.id,
			method: entry.method,
			params: entry.params,
		}));
	}

	/**
	 * Recent frames, oldest first, as one-line summaries. Payloads are described
	 * rather than dumped: the log is a debugging aid, not a transcript, and a
	 * streaming run would otherwise fill it with delta bodies.
	 */
	recentFrames(limit = this.#frameLogLimit): readonly string[] {
		if (limit >= this.#frameLog.length) return [...this.#frameLog];
		return this.#frameLog.slice(this.#frameLog.length - limit);
	}

	/** True when the connected daemon advertises `method` (or before handshake). */
	supports(method: string): boolean {
		if (!this.#helloOk) return true;
		return this.#methods.has(method);
	}

	/**
	 * Open the socket and complete the handshake.
	 * Resolves with the first hello-ok; later reconnects are transparent.
	 */
	connect(timeoutMs = this.#requestTimeoutMs): Promise<HelloOkFrame> {
		if (this.#closed) return Promise.reject(new NotConnectedError(undefined, "client is closed"));
		if (this.#helloOk && this.#state === "online") return Promise.resolve(this.#helloOk);
		const waiter = new Promise<HelloOkFrame>((resolve, reject) => {
			const entry = { resolve, reject };
			this.#handshakeWaiters.push(entry);
			if (timeoutMs > 0) {
				const timer = setTimeout(() => {
					const index = this.#handshakeWaiters.indexOf(entry);
					if (index >= 0) {
						this.#handshakeWaiters.splice(index, 1);
						reject(new HandshakeError(`handshake did not complete within ${timeoutMs}ms`));
					}
				}, timeoutMs);
				timer.unref?.();
			}
		});
		this.#setState(this.#state === "offline" ? "connecting" : this.#state);
		this.#socket.connect();
		return waiter;
	}

	/**
	 * Drop the socket and dial again immediately (`/reconnect`). In-flight
	 * requests fail with NotConnectedError as they would on any disconnect.
	 */
	reconnect(reason = "user requested"): void {
		if (this.#closed) return;
		this.#log(`-- reconnect (${reason})`);
		this.#socket.forceReconnect(reason);
	}

	/** Close permanently. Pending and queued requests reject. */
	close(): void {
		this.#closed = true;
		if (this.#ownsSocket) this.#socket.close();
		this.#failAll(new NotConnectedError(undefined, "client closed"));
		this.#setState("offline");
	}

	/**
	 * Issue a request. Rejects with {@link ControlPlaneError} when the server
	 * answers `ok: false`, {@link RequestTimeoutError} on deadline, and
	 * {@link NotConnectedError} when offline and the method is not queueable.
	 */
	request<T = unknown>(method: string, params?: unknown, options: RequestOptions = {}): Promise<T> {
		if (this.#closed) return Promise.reject(new NotConnectedError(method, "client is closed"));
		const timeoutMs = options.timeoutMs ?? this.#requestTimeoutMs;

		if (this.#state !== "online" && !options.allowWhileConnecting) {
			const queueable = options.queueIfOffline ?? this.#queueableMethods.has(method);
			if (!queueable) return Promise.reject(new NotConnectedError(method));
			return this.#enqueue(method, params, timeoutMs);
		}
		return this.#dispatch(method, params, timeoutMs);
	}

	// -- internals ----------------------------------------------------------

	#wireSocket(): void {
		this.#socket.events.on("open", () => {
			this.#setState(this.#handshakeCount > 0 ? "reconnecting" : "connecting");
			this.#sendHandshake();
		});

		this.#socket.events.on("frame", (raw) => {
			const decoded = tryDecodeFrame(raw);
			if (!decoded.ok) {
				this.events.emit("client-error", { error: decoded.error, context: "decode" });
				return;
			}
			this.#handleFrame(decoded.frame);
		});

		this.#socket.events.on("close", (info) => {
			const wasOnline = this.#state === "online";
			this.#helloOk = undefined;
			this.#handshakeId = undefined;
			this.#failPending(
				new NotConnectedError(
					undefined,
					`connection closed (${info.code}${info.reason ? `: ${info.reason}` : ""})`,
				),
			);
			if (!this.#closed)
				this.#setState(wasOnline || this.#handshakeCount > 0 ? "reconnecting" : "connecting");
		});

		this.#socket.events.on("reconnecting", () => {
			if (!this.#closed) this.#setState("reconnecting");
		});

		this.#socket.events.on("error", (info) => {
			this.events.emit("client-error", info);
		});

		this.#socket.events.on("stale", (info) => {
			this.events.emit("client-error", {
				error: new Error(`no frames for ${info.silentMs}ms (window ${info.windowMs}ms)`),
				context: "liveness",
			});
			void this.#probeLiveness(info.windowMs);
		});
	}

	/**
	 * The daemon sends nothing at all while idle, so silence alone must not cost
	 * the user their connection. Answer a stale window with one cheap read: a
	 * reply proves the socket is alive (and re-arms the watchdog, since any frame
	 * does), and only an unanswered probe forces the reconnect.
	 */
	async #probeLiveness(windowMs: number): Promise<void> {
		if (this.#probeInFlight || this.#state !== "online" || this.#closed) return;
		const method = LIVENESS_PROBE_METHODS.find((candidate) => this.#methods.has(candidate));
		if (!method) {
			// Nothing cheap to ask: fall back to the blunt interpretation.
			this.#socket.forceReconnect();
			return;
		}
		this.#probeInFlight = true;
		try {
			const probeTimeoutMs = Math.min(this.#requestTimeoutMs, Math.max(1000, windowMs));
			await this.#dispatch(method, undefined, probeTimeoutMs);
		} catch (error) {
			if (this.#closed || this.#state !== "online") return;
			this.events.emit("client-error", { error, context: "liveness-probe" });
			this.#socket.forceReconnect("liveness probe failed");
		} finally {
			this.#probeInFlight = false;
		}
	}

	#sendHandshake(): void {
		const params: ConnectParams = {
			role: this.#role,
			client: { id: this.#clientId },
		};
		if (this.#token) params.auth = { token: this.#token };
		const frame = makeReq("connect", params);
		this.#handshakeId = frame.id;
		if (!this.#socket.send(encodeFrame(frame))) {
			this.events.emit("client-error", {
				error: new HandshakeError("failed to send connect frame"),
				context: "handshake",
			});
		}
	}

	/** Append one line to the ring buffer, dropping the oldest when full. */
	#log(line: string): void {
		const stamp = new Date().toISOString().slice(11, 23);
		this.#frameLog.push(`${stamp} ${line}`);
		if (this.#frameLog.length > this.#frameLogLimit) {
			this.#frameLog.splice(0, this.#frameLog.length - this.#frameLogLimit);
		}
	}

	#handleFrame(frame: ResFrame | EventFrame | HelloOkFrame): void {
		if (isHelloOkFrame(frame)) {
			this.#log(
				`<- hello-ok ${frame.server?.version ?? "?"} (${frame.features?.methods?.length ?? 0} methods)`,
			);
			this.#onHelloOk(frame);
			return;
		}
		if (isResFrame(frame)) {
			const pending = this.#pending.get(frame.id);
			this.#log(
				`<- res ${pending?.method ?? frame.id} ${frame.ok ? "ok" : `error ${frame.error?.code ?? "?"}`}`,
			);
			this.#onRes(frame);
			return;
		}
		if (isEventFrame(frame)) {
			this.#log(`<- event ${frame.event}${describeEventPayload(frame.payload)}`);
			this.#onEvent(frame);
		}
	}

	#onHelloOk(hello: HelloOkFrame): void {
		this.#helloOk = hello;
		this.#methods = new Set(hello.features.methods);
		this.#handshakeId = undefined;
		const resumed = this.#handshakeCount > 0;
		this.#handshakeCount += 1;
		this.#socket.setTickIntervalMs(hello.policy?.tickIntervalMs);
		this.#setState("online");
		this.events.emit("hello-ok", { hello, resumed });
		if (resumed) this.events.emit("resync-needed", { hello });

		const waiters = this.#handshakeWaiters;
		this.#handshakeWaiters = [];
		for (const waiter of waiters) waiter.resolve(hello);

		this.#flushQueue();
	}

	#onRes(frame: ResFrame): void {
		// The server answers `connect` with hello-ok, so a res carrying the
		// handshake id can only be an auth rejection.
		if (this.#handshakeId && frame.id === this.#handshakeId) {
			this.#handshakeId = undefined;
			if (!frame.ok) {
				const error = new HandshakeError(
					frame.error?.message ?? "handshake rejected",
					frame.error ? new ControlPlaneError(frame.error, "connect") : undefined,
				);
				const waiters = this.#handshakeWaiters;
				this.#handshakeWaiters = [];
				for (const waiter of waiters) waiter.reject(error);
				this.events.emit("client-error", { error, context: "handshake" });
				return;
			}
		}

		const pending = this.#pending.get(frame.id);
		if (!pending) return;
		this.#pending.delete(frame.id);
		if (pending.timer) clearTimeout(pending.timer);
		if (frame.ok) {
			pending.resolve(frame.payload);
		} else {
			pending.reject(
				new ControlPlaneError(
					frame.error ?? { code: "INTERNAL_ERROR", message: "unknown error" },
					pending.method,
				),
			);
		}
	}

	#onEvent(frame: EventFrame): void {
		this.events.emit("frame", frame);
		const name = frame.event as ProtocolEventName;
		if (this.events.listenerCount(name) > 0 || isKnownEvent(name)) {
			this.events.emit(name, frame.payload as ProtocolEventMap[ProtocolEventName]);
			return;
		}
		this.events.emit("unknown-event", frame);
	}

	#dispatch<T>(method: string, params: unknown, timeoutMs: number, id?: string): Promise<T> {
		return new Promise<T>((resolve, reject) => {
			const frame = makeReq(method, params, id);
			const pending: PendingRequest = { id: frame.id, method, resolve, reject, timer: undefined };
			if (timeoutMs > 0) {
				pending.timer = setTimeout(() => {
					this.#pending.delete(frame.id);
					reject(new RequestTimeoutError(method, timeoutMs));
				}, timeoutMs);
				pending.timer.unref?.();
			}
			this.#pending.set(frame.id, pending);
			this.#log(`-> req ${method}`);
			if (!this.#socket.send(encodeFrame(frame))) {
				this.#pending.delete(frame.id);
				if (pending.timer) clearTimeout(pending.timer);
				reject(new NotConnectedError(method, "socket is not writable"));
			}
		});
	}

	#enqueue<T>(method: string, params: unknown, timeoutMs: number): Promise<T> {
		return new Promise<T>((resolve, reject) => {
			const entry: QueuedRequest = {
				id: crypto.randomUUID(),
				method,
				params,
				timeoutMs,
				resolve,
				reject,
			};
			this.#queue.push(entry);
			this.events.emit("queued", {
				id: entry.id,
				method,
				params,
				queueLength: this.#queue.length,
			});
		});
	}

	#flushQueue(): void {
		if (this.#queue.length === 0) return;
		const entries = this.#queue.splice(0, this.#queue.length);
		for (const entry of entries) {
			this.#dispatch(entry.method, entry.params, entry.timeoutMs, entry.id).then(
				entry.resolve,
				entry.reject,
			);
			this.events.emit("queue-flushed", {
				id: entry.id,
				method: entry.method,
				queueLength: this.#queue.length,
			});
		}
	}

	#failPending(error: unknown): void {
		const pending = [...this.#pending.values()];
		this.#pending.clear();
		for (const entry of pending) {
			if (entry.timer) clearTimeout(entry.timer);
			entry.reject(error);
		}
	}

	#failAll(error: unknown): void {
		this.#failPending(error);
		const queued = this.#queue.splice(0, this.#queue.length);
		for (const entry of queued) entry.reject(error);
		const waiters = this.#handshakeWaiters;
		this.#handshakeWaiters = [];
		for (const waiter of waiters) waiter.reject(error);
	}

	#setState(next: ConnectionState): void {
		if (this.#state === next) return;
		const previous = this.#state;
		this.#state = next;
		this.events.emit("state", { state: next, previous });
	}
}

const KNOWN_EVENTS = new Set<string>([
	"chat",
	"agent",
	"goal",
	"tick",
	"presence",
	"health",
	"shutdown",
	"heartbeat",
	"metrics",
	"log",
	"cron",
	"cron.job",
	"cron.audit",
	"task.started",
	"task.completed",
	"task.error",
	"task.timeout",
	"task.aborted",
	"run.graph.changed",
	"exec.approval.requested",
	"exec.approval.resolved",
	"channel.delivery",
	"talk.mode",
	"voicewake.changed",
	"custom",
]);

function isKnownEvent(name: string): boolean {
	return KNOWN_EVENTS.has(name);
}

/**
 * A short, bounded description of an event payload for the frame log. Streaming
 * deltas are summarized by length: their bodies would swamp the ring buffer and
 * put model output somewhere the user did not ask for it.
 */
function describeEventPayload(payload: unknown): string {
	if (typeof payload !== "object" || payload === null) return "";
	const record = payload as Record<string, unknown>;
	const parts: string[] = [];
	if (typeof record.type === "string") parts.push(record.type);
	if (typeof record.runId === "string") parts.push(record.runId);
	if (typeof record.text === "string") parts.push(`${record.text.length}b`);
	return parts.length > 0 ? ` ${parts.join(" ")}` : "";
}

/**
 * Streaming deltas are per-run monotonic but the transport can redeliver on
 * reconnect. Returns true when the delta is new and updates `lastSeen`.
 */
export function acceptDeltaSeq(lastSeen: Map<string, number>, runId: string, seq: number): boolean {
	if (!Number.isFinite(seq)) return true;
	const previous = lastSeen.get(runId);
	if (previous !== undefined && seq <= previous) return false;
	lastSeen.set(runId, seq);
	return true;
}
