/**
 * Wire frames for the Lemon control-plane WebSocket protocol.
 *
 * Authoritative server-side definition:
 * `apps/lemon_control_plane/lib/lemon_control_plane/protocol/frames.ex`.
 *
 * Four frame types travel over a single JSON text channel:
 *   - `req`      client -> server
 *   - `res`      server -> client (correlated by `id`)
 *   - `event`    server -> client (unsolicited, monotonic `seq`)
 *   - `hello-ok` server -> client, sent *instead of* a `res` for `connect`
 */

/** Error body carried by `res` frames with `ok: false`. */
export interface ProtocolErrorPayload {
	code: string;
	message: string;
	details?: unknown;
}

export interface ReqFrame {
	type: "req";
	id: string;
	method: string;
	params?: unknown;
}

export interface ResFrame {
	type: "res";
	id: string;
	ok: boolean;
	payload?: unknown;
	error?: ProtocolErrorPayload;
}

export interface EventFrame {
	type: "event";
	event: string;
	payload?: unknown;
	seq: number;
	stateVersion?: Record<string, number>;
}

export interface HelloOkServer {
	version?: string;
	commit?: string;
	host?: string;
	connId?: string;
}

export interface HelloOkFeatures {
	methods: string[];
	events: string[];
}

export interface HelloOkPolicy {
	maxPayload: number;
	maxBufferedBytes: number;
	tickIntervalMs: number;
}

export interface HelloOkAuth {
	role?: string;
	scopes?: string[];
	clientId?: string;
}

export interface HelloOkFrame {
	type: "hello-ok";
	protocol: number;
	server: HelloOkServer;
	features: HelloOkFeatures;
	snapshot?: Record<string, unknown>;
	policy: HelloOkPolicy;
	auth?: HelloOkAuth;
}

export type ClientFrame = ReqFrame;
export type ServerFrame = ResFrame | EventFrame | HelloOkFrame;

/** Policy defaults mirroring `Frames.encode_hello_ok/1`. */
export const DEFAULT_POLICY: HelloOkPolicy = {
	maxPayload: 1_048_576,
	maxBufferedBytes: 8_388_608,
	tickIntervalMs: 1000,
};

export class FrameDecodeError extends Error {
	readonly raw: string;

	constructor(message: string, raw: string) {
		super(message);
		this.name = "FrameDecodeError";
		this.raw = raw;
	}
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function isResFrame(frame: unknown): frame is ResFrame {
	return isRecord(frame) && frame.type === "res" && typeof frame.id === "string";
}

export function isEventFrame(frame: unknown): frame is EventFrame {
	return isRecord(frame) && frame.type === "event" && typeof frame.event === "string";
}

export function isHelloOkFrame(frame: unknown): frame is HelloOkFrame {
	return isRecord(frame) && frame.type === "hello-ok";
}

export function isServerFrame(frame: unknown): frame is ServerFrame {
	return isResFrame(frame) || isEventFrame(frame) || isHelloOkFrame(frame);
}

/** Build a request frame. `id` defaults to a fresh UUID. */
export function makeReq(
	method: string,
	params?: unknown,
	id: string = crypto.randomUUID(),
): ReqFrame {
	const frame: ReqFrame = { type: "req", id, method };
	if (params !== undefined) frame.params = params;
	return frame;
}

export function encodeFrame(frame: ClientFrame): string {
	return JSON.stringify(frame);
}

/**
 * Decode one server frame. Throws {@link FrameDecodeError} on malformed JSON or
 * an unrecognized `type` — callers on the socket path should prefer
 * {@link tryDecodeFrame} so one bad frame cannot kill the connection.
 */
export function decodeFrame(data: string): ServerFrame {
	let parsed: unknown;
	try {
		parsed = JSON.parse(data);
	} catch (error) {
		throw new FrameDecodeError(
			`invalid JSON frame: ${error instanceof Error ? error.message : String(error)}`,
			data,
		);
	}
	if (!isRecord(parsed)) {
		throw new FrameDecodeError("frame must be a JSON object", data);
	}
	if (typeof parsed.type !== "string") {
		throw new FrameDecodeError("frame must have a string type field", data);
	}
	if (!isServerFrame(parsed)) {
		throw new FrameDecodeError(`unsupported frame type: ${parsed.type}`, data);
	}
	if (isHelloOkFrame(parsed)) {
		return normalizeHelloOk(parsed);
	}
	return parsed;
}

export type DecodeResult =
	| { ok: true; frame: ServerFrame }
	| { ok: false; error: FrameDecodeError };

export function tryDecodeFrame(data: string): DecodeResult {
	try {
		return { ok: true, frame: decodeFrame(data) };
	} catch (error) {
		if (error instanceof FrameDecodeError) return { ok: false, error };
		return { ok: false, error: new FrameDecodeError(String(error), data) };
	}
}

/** Fill in the optional halves of hello-ok so consumers never branch on undefined. */
export function normalizeHelloOk(frame: HelloOkFrame): HelloOkFrame {
	const features = frame.features ?? { methods: [], events: [] };
	return {
		...frame,
		protocol: typeof frame.protocol === "number" ? frame.protocol : 1,
		server: frame.server ?? {},
		features: {
			methods: Array.isArray(features.methods) ? features.methods : [],
			events: Array.isArray(features.events) ? features.events : [],
		},
		policy: { ...DEFAULT_POLICY, ...(frame.policy ?? {}) },
	};
}
