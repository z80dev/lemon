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

/** A request was issued while the client had no live, handshaken connection. */
export class NotConnectedError extends Error {
	readonly code = "NOT_CONNECTED";
	readonly method?: string;

	constructor(method?: string, message?: string) {
		super(message ?? (method ? `not connected (${method})` : "not connected"));
		this.name = "NotConnectedError";
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
	if (error instanceof NotConnectedError) return "not connected — run /reconnect, then try again";
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
