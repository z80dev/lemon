/** Authenticated real-Bandit proof for the read-scoped sessions.stats RPC. */

import { ControlPlaneClient } from "../src/protocol/client.ts";
import { ControlPlaneError } from "../src/protocol/errors.ts";

const [url, token, query, secret] = process.argv.slice(2);
if (!url || !token || !query || !secret) {
	throw new Error("usage: bun session-stats-wire-proof.ts <ws-url> <token> <query> <secret>");
}

interface StatsReport {
	redacted?: boolean;
	totals?: { matchedSessions?: number; pinnedSessions?: number; runs?: number };
	cleanup?: { includesSessionKeys?: boolean; includesPrompts?: boolean };
}

const client = new ControlPlaneClient({
	url,
	token,
	clientId: "lemon-session-stats-wire-proof",
	requestTimeoutMs: 5_000,
	socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
});

try {
	const hello = await client.connect();
	assert(hello.auth?.role === "operator", "operator authentication");

	const report = await client.request<StatsReport>("sessions.stats", {
		query,
		pinned: true,
		groupLimit: 5,
	});

	assert(report.redacted === true, "redacted marker");
	assert(report.totals?.matchedSessions === 1, "exact matched sessions");
	assert(report.totals?.pinnedSessions === 1, "exact pinned sessions");
	assert(report.totals?.runs === 1, "canonical run total");
	assert(report.cleanup?.includesSessionKeys === false, "session keys omitted");
	assert(report.cleanup?.includesPrompts === false, "prompts omitted");
	assert(JSON.stringify(report).includes(secret) === false, "secret omitted");
	assert(JSON.stringify(report).includes("sessionKey") === false, "session key fields omitted");

	let invalidRefused = false;
	try {
		await client.request("sessions.stats", { query: "x".repeat(513) });
	} catch (error) {
		invalidRefused = ControlPlaneError.is(error, "INVALID_PARAMS");
	}
	assert(invalidRefused, "oversized query refused");

	console.log(JSON.stringify({ ok: true, matchedSessions: 1, runs: 1, redacted: true }));
} finally {
	client.close();
}

function assert(condition: unknown, label: string): asserts condition {
	if (!condition) throw new Error(`session stats wire proof failed: ${label}`);
}
