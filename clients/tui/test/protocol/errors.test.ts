import { describe, expect, test } from "bun:test";
import {
	AuthenticationError,
	ConnectionLostError,
	ControlPlaneError,
	classifyMutationError,
	describeError,
	HandshakeError,
	MethodUnavailableError,
	NotConnectedError,
	RequestTimeoutError,
} from "../../src/protocol/errors.ts";

describe("user-facing protocol failures", () => {
	test("offline, timeout and unavailable actions explain recovery without protocol details", () => {
		const cases = [
			[new NotConnectedError("chat.send", "connection closed (1006: )"), "/reconnect"],
			[new RequestTimeoutError("status", 15000), "within 15s"],
			[new MethodUnavailableError("sessions.patch"), "update Lemon"],
			[
				new ControlPlaneError({ code: "HANDSHAKE_REQUIRED", message: "HANDSHAKE_REQUIRED" }),
				"/reconnect",
			],
		] as const;
		for (const [error, recovery] of cases) {
			const message = describeError(error);
			expect(message).toContain(recovery);
			expect(message).not.toMatch(/chat\.send|sessions\.patch|1006|HANDSHAKE|method "|request "/);
		}
	});

	test("auth rejection identifies environment and managed-token recovery without echoing credentials", () => {
		const error = new AuthenticationError(new Error("secret-token"));
		expect(describeError(error)).toContain("auth rejected");
		expect(describeError(error)).toContain("LEMON_CONTROL_PLANE_OPERATOR_TOKEN");
		expect(describeError(error)).toContain("~/.lemon/run/control-plane-<port>.token");
		expect(describeError(error)).toContain("restart the TUI");
		expect(describeError(error)).not.toContain("secret-token");
	});
});

describe("classifyMutationError", () => {
	const refusal = (code: string, details?: unknown) =>
		new ControlPlaneError({ code, message: code, details });

	test.each([
		["the pre-send gate", new NotConnectedError("chat.send"), "not-sent"],
		["an unadvertised method", new MethodUnavailableError("chat.send"), "not-sent"],
		["a refused handshake", new HandshakeError("refused"), "not-sent"],
		["a connection lost after dispatch", new ConnectionLostError("chat.send"), "unknown"],
		["a timeout", new RequestTimeoutError("chat.send", 15_000), "unknown"],
		["an unreadable receipt", new Error("unverified send receipt"), "unknown"],
		["a generic server failure", refusal("INTERNAL_ERROR"), "unknown"],
		["an unavailable service", refusal("UNAVAILABLE"), "unknown"],
		["an unknown server code", refusal("SOMETHING_NEW"), "unknown"],
		["retrySafe: false", refusal("CONFLICT", { retrySafe: false }), "unknown"],
		["reason outcome_unknown", refusal("UNAVAILABLE", { reason: "outcome_unknown" }), "unknown"],
		["retrySafe: true", refusal("UNAVAILABLE", { retrySafe: true }), "refused"],
		["an allow-listed refusal", refusal("CONFLICT"), "refused"],
		["invalid params", refusal("INVALID_PARAMS"), "refused"],
	] as const)("%s is %s", (_label, error, outcome) => {
		expect(classifyMutationError(error)).toBe(outcome);
	});

	test("a lost connection is reported as an unknown outcome, never as not sent", () => {
		const message = describeError(new ConnectionLostError("chat.send", "connection closed (1006)"));
		expect(message).toContain("outcome is unknown");
		expect(message).not.toContain("nothing was sent");
		expect(message).not.toMatch(/chat\.send|1006/);
		expect(describeError(new NotConnectedError("chat.send"))).toContain("nothing was sent");
	});
});
