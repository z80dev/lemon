import type { ConnectParams } from "../../../src/protocol/types.ts";

/**
 * Authenticated connect shape accepted by the BEAM control plane.
 *
 * The authoritative contract lives in Protocol.Schemas (`auth` is a map) and
 * Auth.Authorize (`params["auth"]["token"]`). Keeping this fixture next to the
 * client test makes the cross-language envelope explicit.
 */
export const AUTHENTICATED_CONNECT_PARAMS = {
	role: "operator",
	client: { id: "lemon-tui@test-auth" },
	auth: { token: "paired-session-token" },
} satisfies ConnectParams;
