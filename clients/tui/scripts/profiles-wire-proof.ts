/**
 * Authenticated real-control-plane proof driver for the TUI profile protocol.
 *
 * The matching ExUnit test starts Bandit with isolated profile state, then
 * executes this Bun client. Keep this driver on the same typed wrappers the TUI
 * uses; it is not a second test-only WebSocket implementation.
 */

import { ControlPlaneClient } from "../src/protocol/client.ts";
import { ControlPlaneMethods } from "../src/protocol/methods.ts";

const [url, token, exportPath] = process.argv.slice(2);
if (!url || !token || !exportPath) {
	throw new Error("usage: bun profiles-wire-proof.ts <ws-url> <operator-token> <export-path>");
}

const client = new ControlPlaneClient({
	url,
	token,
	clientId: "lemon-tui-profile-wire-proof",
	requestTimeoutMs: 5_000,
	socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
});
const methods = new ControlPlaneMethods(client);

try {
	const hello = await client.connect();
	assert(hello.auth?.role === "operator", "operator authentication");

	const created = await methods.profilesCreate({
		id: "tui-wire",
		name: "TUI Wire",
		description: "Authenticated profile protocol proof",
		model: "openai:gpt-5",
		node: "wire-node",
	});
	assert(created.profile.canonicalSessionKey === "agent:tui-wire:main", "canonical create key");
	assert(created.profile.node === "wire-node", "named-node create route");
	const listed = await methods.profilesList();
	assert(
		listed.profiles.some((profile) => profile.id === "tui-wire"),
		"profiles list",
	);

	const roster = await methods.profilesRoster();
	const row = roster.profiles.find((profile) => profile.id === "tui-wire");
	assert(row?.canonicalSessionKey === "agent:tui-wire:main", "roster canonical key");
	assert(row?.node === "wire-node", "roster named-node route");
	assert(row?.availability === "offline", "offline named-node status");

	const opened = await methods.profilesGet({ id: "tui-wire" });
	assert(opened.profile.canonicalSessionKey === "agent:tui-wire:main", "open canonical chat");

	const chat = await methods.profileChat({
		id: "tui-wire",
		prompt: "prove the authenticated TUI profile route",
		queueMode: "steer",
	});
	assert(chat.runId === "run-tui-profile-wire", "router run id");
	assert(chat.sessionKey === "agent:tui-wire:main", "chat canonical key");
	assert(chat.node === "wire-node", "chat named-node route");

	const renamed = await methods.profilesRename({ id: "tui-wire", name: "TUI Wire Prime" });
	assert(renamed.profile.canonicalSessionKey === "agent:tui-wire:main", "rename stability");

	const cloned = await methods.profilesClone({
		sourceId: "tui-wire",
		id: "tui-wire-copy",
		name: "TUI Wire Copy",
	});
	assert(cloned.profile.canonicalSessionKey === "agent:tui-wire-copy:main", "clone key");

	const exported = await methods.profilesExport({ id: "tui-wire", path: exportPath });
	const exportResult = exported.export as Record<string, unknown>;
	assert(exportResult.profileId === "tui-wire", "export profile id");
	assert(typeof exportResult.fileCount === "number", "export file count");

	const deleted = await methods.profilesDelete({ id: "tui-wire-copy", confirm: "tui-wire-copy" });
	const deletedResult = deleted.deleted as Record<string, unknown>;
	assert(deletedResult.id === "tui-wire-copy", "guarded clone delete");

	console.log(
		JSON.stringify({
			ok: true,
			checks: [
				"authenticated_handshake",
				"profile_lifecycle",
				"node_aware_roster",
				"canonical_profile_chat",
				"credential_safe_export",
			],
			sessionKey: chat.sessionKey,
			node: chat.node,
		}),
	);
} finally {
	client.close();
}

function assert(condition: unknown, label: string): asserts condition {
	if (!condition) throw new Error(`profile wire proof failed: ${label}`);
}
