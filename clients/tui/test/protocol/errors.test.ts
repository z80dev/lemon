import { describe, expect, test } from "bun:test";
import {
	AuthenticationError,
	ControlPlaneError,
	describeError,
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
