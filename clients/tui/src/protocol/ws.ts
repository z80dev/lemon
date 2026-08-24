/**
 * Auto-reconnecting WebSocket transport.
 *
 * Bun's native `WebSocket` only — no `ws` package. The socket owns exactly two
 * concerns: staying connected (exponential backoff with jitter) and noticing
 * that a connection has gone quiet (liveness watchdog). Framing, correlation and
 * handshake live one layer up in `client.ts`.
 */

import { Emitter } from "../store/events.ts";

export type SocketState = "idle" | "connecting" | "open" | "reconnecting" | "closed";

export interface SocketCloseInfo {
	code: number;
	reason: string;
	wasClean: boolean;
}

export interface ReconnectingSocketEvents {
	open: { attempt: number; reconnected: boolean };
	/** A raw text frame straight off the wire. */
	frame: string;
	close: SocketCloseInfo;
	reconnecting: { attempt: number; delayMs: number };
	error: { error: unknown; context: string };
	/** The liveness watchdog fired: no frame within the allowed window. */
	stale: { silentMs: number; windowMs: number };
}

export interface ReconnectingSocketOptions {
	url: string;
	/** First backoff step. Default 500ms. */
	minBackoffMs?: number;
	/** Backoff ceiling. Default 15_000ms. */
	maxBackoffMs?: number;
	/** Jitter fraction applied to each delay, 0..1. Default 0.25. */
	jitter?: number;
	/**
	 * Liveness window = `watchdogMultiplier` x the server's tick interval.
	 * The watchdog is only armed once {@link setTickIntervalMs} supplies that
	 * interval from hello-ok. Default 3.
	 */
	watchdogMultiplier?: number;
	/**
	 * Floor for the liveness window. Default {@link MIN_WATCHDOG_WINDOW_MS};
	 * tests with millisecond ticks pass 0 to disable the floor.
	 */
	minWatchdogWindowMs?: number;
	/** Injectable for tests. */
	webSocketImpl?: typeof WebSocket;
	/** Injectable clock, for tests. */
	now?: () => number;
	/** Deterministic jitter source, for tests. */
	random?: () => number;
}

/** Floor for the liveness window regardless of the server's tick interval. */
export const MIN_WATCHDOG_WINDOW_MS = 10_000;

/** Pure backoff math, exported so tests can assert the curve without timers. */
export function computeBackoffDelay(
	attempt: number,
	options: { minBackoffMs?: number; maxBackoffMs?: number; jitter?: number } = {},
	random: () => number = Math.random,
): number {
	const min = options.minBackoffMs ?? 500;
	const max = options.maxBackoffMs ?? 15_000;
	const jitter = options.jitter ?? 0.25;
	const exponent = Math.max(0, attempt - 1);
	const base = Math.min(max, min * 2 ** exponent);
	// Symmetric jitter around `base`, clamped into [min/2, max].
	const factor = 1 + (random() * 2 - 1) * jitter;
	return Math.min(max, Math.max(Math.floor(min / 2), Math.round(base * factor)));
}

export class ReconnectingSocket {
	readonly events = new Emitter<ReconnectingSocketEvents>();

	readonly #url: string;
	readonly #options: Required<Omit<ReconnectingSocketOptions, "url" | "webSocketImpl">> & {
		webSocketImpl: typeof WebSocket;
	};

	#socket: WebSocket | undefined;
	#state: SocketState = "idle";
	#attempt = 0;
	#everConnected = false;
	#closedByUser = false;
	#reconnectTimer: ReturnType<typeof setTimeout> | undefined;
	#watchdogTimer: ReturnType<typeof setTimeout> | undefined;
	#watchdogWindowMs: number | undefined;
	#lastFrameAt = 0;

	constructor(options: ReconnectingSocketOptions) {
		this.#url = options.url;
		this.#options = {
			minBackoffMs: options.minBackoffMs ?? 500,
			maxBackoffMs: options.maxBackoffMs ?? 15_000,
			jitter: options.jitter ?? 0.25,
			watchdogMultiplier: options.watchdogMultiplier ?? 3,
			minWatchdogWindowMs: options.minWatchdogWindowMs ?? MIN_WATCHDOG_WINDOW_MS,
			now: options.now ?? (() => Date.now()),
			random: options.random ?? Math.random,
			webSocketImpl: options.webSocketImpl ?? WebSocket,
		};
	}

	get url(): string {
		return this.#url;
	}

	get state(): SocketState {
		return this.#state;
	}

	get isOpen(): boolean {
		return this.#state === "open";
	}

	/** Open the socket (idempotent). Reconnects are automatic afterwards. */
	connect(): void {
		if (this.#state === "connecting" || this.#state === "open") return;
		this.#closedByUser = false;
		this.#openSocket();
	}

	/** Send a text frame. Returns false when the socket is not open. */
	send(data: string): boolean {
		if (!this.#socket || this.#state !== "open") return false;
		try {
			this.#socket.send(data);
			return true;
		} catch (error) {
			this.events.emit("error", { error, context: "send" });
			return false;
		}
	}

	/** Close permanently: no reconnect is scheduled. */
	close(code = 1000, reason = "client closed"): void {
		this.#closedByUser = true;
		this.#clearReconnectTimer();
		this.#clearWatchdog();
		this.#state = "closed";
		const socket = this.#socket;
		this.#socket = undefined;
		if (socket) {
			this.#detach(socket);
			try {
				socket.close(code, reason);
			} catch {
				// A socket still in CONNECTING throws on close in some runtimes.
			}
		}
	}

	/**
	 * Arm (or re-arm) the liveness watchdog from the server's policy.
	 * Passing `undefined` disarms it.
	 */
	setTickIntervalMs(tickIntervalMs: number | undefined): void {
		if (tickIntervalMs === undefined || !Number.isFinite(tickIntervalMs) || tickIntervalMs <= 0) {
			this.#watchdogWindowMs = undefined;
			this.#clearWatchdog();
			return;
		}
		// A 1s server tick would give a 3s window — tight enough that a busy
		// BEAM scheduler or GC pause trips a spurious mid-run reconnect (seen
		// live). Never allow the window below the configured floor.
		this.#watchdogWindowMs = Math.max(
			tickIntervalMs * this.#options.watchdogMultiplier,
			this.#options.minWatchdogWindowMs,
		);
		this.#armWatchdog();
	}

	get livenessWindowMs(): number | undefined {
		return this.#watchdogWindowMs;
	}

	// -- internals ----------------------------------------------------------

	#openSocket(): void {
		this.#state = this.#everConnected ? "reconnecting" : "connecting";
		this.#attempt += 1;
		let socket: WebSocket;
		try {
			socket = new this.#options.webSocketImpl(this.#url);
		} catch (error) {
			this.events.emit("error", { error, context: "construct" });
			this.#scheduleReconnect();
			return;
		}
		this.#socket = socket;

		socket.onopen = () => {
			if (this.#socket !== socket) return;
			this.#state = "open";
			const reconnected = this.#everConnected;
			this.#everConnected = true;
			this.#lastFrameAt = this.#options.now();
			this.#armWatchdog();
			this.events.emit("open", { attempt: this.#attempt, reconnected });
			this.#attempt = 0;
		};

		socket.onmessage = (event: MessageEvent) => {
			if (this.#socket !== socket) return;
			this.#lastFrameAt = this.#options.now();
			this.#armWatchdog();
			const data = event.data;
			if (typeof data === "string") {
				this.events.emit("frame", data);
				return;
			}
			// The daemon only speaks JSON text; decode defensively anyway.
			if (data instanceof ArrayBuffer) {
				this.events.emit("frame", new TextDecoder().decode(data));
				return;
			}
			this.events.emit("error", {
				error: new Error("unsupported frame payload"),
				context: "message",
			});
		};

		socket.onerror = (error: unknown) => {
			if (this.#socket !== socket) return;
			this.events.emit("error", { error, context: "socket" });
		};

		socket.onclose = (event: CloseEvent) => {
			if (this.#socket !== socket) return;
			this.#socket = undefined;
			this.#clearWatchdog();
			this.events.emit("close", {
				code: event?.code ?? 1006,
				reason: event?.reason ?? "",
				wasClean: Boolean(event?.wasClean),
			});
			if (!this.#closedByUser) this.#scheduleReconnect();
		};
	}

	#detach(socket: WebSocket): void {
		socket.onopen = null;
		socket.onmessage = null;
		socket.onerror = null;
		socket.onclose = null;
	}

	#scheduleReconnect(): void {
		if (this.#closedByUser) return;
		this.#clearReconnectTimer();
		this.#state = "reconnecting";
		const attempt = Math.max(1, this.#attempt);
		const delayMs = computeBackoffDelay(attempt, this.#options, this.#options.random);
		this.events.emit("reconnecting", { attempt, delayMs });
		this.#reconnectTimer = setTimeout(() => {
			this.#reconnectTimer = undefined;
			if (this.#closedByUser) return;
			this.#openSocket();
		}, delayMs);
		this.#reconnectTimer.unref?.();
	}

	#clearReconnectTimer(): void {
		if (this.#reconnectTimer) {
			clearTimeout(this.#reconnectTimer);
			this.#reconnectTimer = undefined;
		}
	}

	#armWatchdog(): void {
		this.#clearWatchdog();
		const windowMs = this.#watchdogWindowMs;
		if (windowMs === undefined || this.#state !== "open") return;
		this.#watchdogTimer = setTimeout(() => {
			this.#watchdogTimer = undefined;
			if (this.#state !== "open") return;
			const silentMs = this.#options.now() - this.#lastFrameAt;
			if (silentMs < windowMs) {
				// A frame landed while the timer was in flight; re-arm for the rest.
				this.#armWatchdog();
				return;
			}
			// Silence is suspicious, not proof of death: an idle daemon sends no
			// frames at all. The owner (client.ts) probes with a cheap request and
			// calls forceReconnect() only if that probe goes unanswered. Re-arm so
			// a connection that stays quiet keeps being checked.
			this.events.emit("stale", { silentMs, windowMs });
			this.#armWatchdog();
		}, windowMs);
		this.#watchdogTimer.unref?.();
	}

	#clearWatchdog(): void {
		if (this.#watchdogTimer) {
			clearTimeout(this.#watchdogTimer);
			this.#watchdogTimer = undefined;
		}
	}

	/** Drop a connection believed dead and reconnect on the usual backoff. */
	forceReconnect(reason = "liveness watchdog"): void {
		if (this.#closedByUser) return;
		this.#clearWatchdog();
		const socket = this.#socket;
		this.#socket = undefined;
		if (socket) {
			this.#detach(socket);
			try {
				socket.close(4000, reason);
			} catch {
				// Already closing; the scheduled reconnect below still applies.
			}
		}
		this.events.emit("close", { code: 4000, reason, wasClean: false });
		this.#scheduleReconnect();
	}
}
