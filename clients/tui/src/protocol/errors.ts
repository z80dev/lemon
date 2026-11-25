/**
 * Typed failures raised by the protocol layer.
 *
 * Server error codes are the strings in
 * `apps/lemon_control_plane/lib/lemon_control_plane/protocol/errors.ex`.
 */

import type { ProtocolErrorPayload } from "./frames.ts";

/** Server error codes, as sent in `res.error.code`. */
export const ERROR_CODES = [
	"INVALID_REQUEST",
	"INVALID_PARAMS",
	"METHOD_NOT_FOUND",
	"UNAUTHORIZED",
	"FORBIDDEN",
	"PERMISSION_DENIED",
	"NOT_FOUND",
	"CONFLICT",
	"RATE_LIMITED",
	"TIMEOUT",
	"INTERNAL_ERROR",
	"NOT_IMPLEMENTED",
	"HANDSHAKE_REQUIRED",
	"ALREADY_CONNECTED",
	"UNAVAILABLE",
] as const;

export type ServerErrorCode = (typeof ERROR_CODES)[number];

/** An `ok: false` response from the daemon. */
export class ControlPlaneError extends Error {
	readonly code: string;
	readonly details: unknown;
	readonly method?: string;

	constructor(payload: ProtocolErrorPayload, method?: string) {
		super(payload?.message || payload?.code || "control plane error");
		this.name = "ControlPlaneError";
		this.code = payload?.code ?? "INTERNAL_ERROR";
		this.details = payload?.details;
		this.method = method;
	}

	static is(error: unknown, code?: string): error is ControlPlaneError {
		return error instanceof ControlPlaneError && (code === undefined || error.code === code);
	}
}

/**
 * A request was refused before it reached the socket: the client had no live,
 * handshaken connection (or the socket would not take the frame). Nothing was
 * sent, so the daemon cannot have acted on it.
 */
export class NotConnectedError extends Error {
	readonly code = "NOT_CONNECTED";
	readonly method?: string;

	constructor(method?: string, message?: string) {
		super(message ?? (method ? `not connected (${method})` : "not connected"));
		this.name = "NotConnectedError";
		this.method = method;
	}
}

/**
 * The connection dropped after the request was written to the socket and before
 * its answer arrived. The daemon may already have acted on it: the outcome is
 * unknown, and a mutation must not be retried before its target is inspected.
 */
export class ConnectionLostError extends Error {
	readonly code = "CONNECTION_LOST";
	readonly method?: string;

	constructor(method?: string, reason?: string) {
		super(
			`connection lost before ${method ? `"${method}"` : "the request"} was answered${reason ? ` (${reason})` : ""}`,
		);
		this.name = "ConnectionLostError";
		this.method = method;
	}
}

/** No `res` arrived within the request deadline. */
export class RequestTimeoutError extends Error {
	readonly code = "REQUEST_TIMEOUT";
	readonly method: string;
	readonly timeoutMs: number;

	constructor(method: string, timeoutMs: number) {
		super(`request "${method}" timed out after ${timeoutMs}ms`);
		this.name = "RequestTimeoutError";
		this.method = method;
		this.timeoutMs = timeoutMs;
	}
}

/**
 * The connected daemon does not advertise the method in
 * `hello-ok.features.methods`. Callers degrade gracefully instead of sending a
 * request the server would reject.
 */
export class MethodUnavailableError extends Error {
	readonly code = "METHOD_UNAVAILABLE";
	readonly method: string;

	constructor(method: string) {
		super(`method "${method}" is not available on this daemon`);
		this.name = "MethodUnavailableError";
		this.method = method;
	}
}

/** The handshake itself failed (auth rejected, or no hello-ok in time). */
export class HandshakeError extends Error {
	readonly code = "HANDSHAKE_FAILED";
	readonly cause?: unknown;

	constructor(message: string, cause?: unknown) {
		super(message);
		this.name = "HandshakeError";
		this.cause = cause;
	}
}

/** Authentication failed; retrying the same credential cannot recover it. */
export class AuthenticationError extends HandshakeError {
	constructor(cause?: unknown) {
		super(
			"auth rejected — set LEMON_CONTROL_PLANE_OPERATOR_TOKEN to the runtime's token and restart the TUI, or use the lemon launcher to load ~/.lemon/run/control-plane-<port>.token",
			cause,
		);
		this.name = "AuthenticationError";
	}
}

export function offlineMessage(url: string): string {
	return `Lemon isn't running at ${url}. Start it with \`lemon start\`, then /reconnect (or check --url / LEMON_WS_URL).`;
}

/** User-facing failures; method names, close codes and wire details stay in /debug. */
export function describeError(error: unknown): string {
	if (error instanceof AuthenticationError) return error.message;
	if (error instanceof NotConnectedError)
		return "not connected — nothing was sent; run /reconnect, then try again";
	if (error instanceof ConnectionLostError)
		return "the connection dropped before Lemon answered — the outcome is unknown; check before trying again";
	if (error instanceof RequestTimeoutError)
		return `Lemon did not answer within ${error.timeoutMs / 1000}s — run /reconnect before trying again`;
	if (error instanceof MethodUnavailableError)
		return "this action needs a newer Lemon runtime — update Lemon, then /reconnect";
	if (error instanceof HandshakeError) return error.message;
	if (error instanceof ControlPlaneError) {
		switch (error.code) {
			case "HANDSHAKE_REQUIRED":
			case "ALREADY_CONNECTED":
				return "the connection is not ready — run /reconnect, then try again";
			case "METHOD_NOT_FOUND":
			case "NOT_IMPLEMENTED":
				return "this action is unavailable — update Lemon, then /reconnect";
			case "INTERNAL_ERROR":
				return "Lemon could not complete this action — check the runtime logs";
		}
	}
	return error instanceof Error ? error.message : String(error);
}

/**
 * What a failed mutation proves about its effect:
 *   `not-sent`  the request never reached the daemon (pre-send gate, unsupported method);
 *   `refused`   the daemon answered with a definite refusal — nothing was changed;
 *   `unknown`   it may have taken effect (connection lost after dispatch, timeout,
 *               `retrySafe: false`, a generic server failure, an unreadable receipt).
 * Only `not-sent` and `refused` may ever be offered for an automatic or blind retry.
 */
export type MutationOutcome = "not-sent" | "refused" | "unknown";

/** Server codes that refuse a request before it changes anything. */
const REFUSAL_CODES: Readonly<Partial<Record<string, true>>> = {
	INVALID_REQUEST: true,
	INVALID_PARAMS: true,
	METHOD_NOT_FOUND: true,
	UNAUTHORIZED: true,
	FORBIDDEN: true,
	PERMISSION_DENIED: true,
	NOT_FOUND: true,
	CONFLICT: true,
	RATE_LIMITED: true,
	NOT_IMPLEMENTED: true,
	HANDSHAKE_REQUIRED: true,
	ALREADY_CONNECTED: true,
	callback_origin_not_allowed: true,
	callback_requires_https: true,
	invalid_callback_url: true,
};

export function classifyMutationError(error: unknown): MutationOutcome {
	if (
		error instanceof NotConnectedError ||
		error instanceof MethodUnavailableError ||
		error instanceof HandshakeError
	) {
		return "not-sent";
	}
	if (error instanceof ControlPlaneError) {
		const details =
			typeof error.details === "object" && error.details !== null
				? (error.details as { retrySafe?: unknown; reason?: unknown })
				: undefined;
		if (details?.retrySafe === false || details?.reason === "outcome_unknown") return "unknown";
		if (details?.retrySafe === true) return "refused";
		return REFUSAL_CODES[error.code] === true ? "refused" : "unknown";
	}
	return "unknown";
}

/** The protocol-level code of a failure, or `fallback` for a local/receipt error. */
export function failureCode(error: unknown, fallback: string): string {
	return error instanceof ControlPlaneError ||
		error instanceof NotConnectedError ||
		error instanceof ConnectionLostError ||
		error instanceof RequestTimeoutError ||
		error instanceof MethodUnavailableError ||
		error instanceof HandshakeError
		? error.code
		: fallback;
}

/**
 * The daemon's answer to resolving an approval whose run ended: `CONFLICT` with
 * `details.reason === "expired"`. The request can never be answered, so a
 * client forgets it rather than offering it again.
 */
export function isExpiredApprovalError(error: unknown): error is ControlPlaneError {
	if (!ControlPlaneError.is(error, "CONFLICT")) return false;
	const details = error.details;
	return (
		typeof details === "object" &&
		details !== null &&
		(details as { reason?: unknown }).reason === "expired"
	);
}

/**
 * The daemon could not confirm an approval write: `UNAVAILABLE` with
 * `details.reason === "outcome_unknown"`. The action did not run, the decision
 * is neither denied nor cancelled, and the client must not retry it.
 */
export function isOutcomeUnknownApprovalError(error: unknown): error is ControlPlaneError {
	if (!ControlPlaneError.is(error, "UNAVAILABLE")) return false;
	const details = error.details;
	return (
		typeof details === "object" &&
		details !== null &&
		"reason" in details &&
		details.reason === "outcome_unknown"
	);
}
