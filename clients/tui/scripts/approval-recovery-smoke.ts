import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { AppShell } from "../src/app.ts";
import type { ExecPendingApproval } from "../src/protocol/types.ts";
import { initTheme, resetTheme } from "../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../src/ui/theme/tui-adapters.ts";
import { MemoryTerminal, renderPlain } from "../test/helpers/memory-terminal.ts";

// No bun:test/ExUnit, fake transport, providers, browser, or prompt submission.
// The companion isolated backend owns every approval and serves production WS RPCs.
interface Manifest {
	url: string;
	credentialFile: string;
	sessionKey: string;
	cwd: string;
	approvalIds: [string, string];
}

async function run() {
	const manifest = JSON.parse(await readFile(process.argv[2]!, "utf8")) as Manifest;
	assert.equal(new URL(manifest.url).hostname, "127.0.0.1");
	const token = (await readFile(manifest.credentialFile, "utf8")).trim();
	const [first, second] = manifest.approvalIds;
	initTheme({ colorLevel: 0 });
	let app: AppShell | undefined;
	const boot = async () => {
		app = new AppShell({
			url: manifest.url,
			operatorToken: token,
			sessionKey: manifest.sessionKey,
			cwd: manifest.cwd,
			terminal: new MemoryTerminal(),
			smoothStreaming: false,
		});
		await app.start();
		assert.equal(app.client.online, true);
		assert.equal(app.methods.supports("sessions.snapshot"), true);
		await app.sessions.resync();
		return app;
	};
	try {
		let current = await boot();
		const raw = await current.methods.sessionsSnapshot({
			sessionKey: manifest.sessionKey,
			cwd: manifest.cwd,
		});
		assert.equal(raw.status, "ok");
		if (raw.status !== "ok") throw new Error("owner snapshot raced");
		assert.equal(raw.snapshot.approvals.status, "ok");
		assert.deepEqual(
			raw.snapshot.approvals.items.map((row) => row.id).sort(),
			[first, second].sort(),
		);
		assert.equal(
			raw.snapshot.approvals.items.every((row) => !("approvalId" in row)),
			true,
		);
		assert.deepEqual([...current.store.approvals.keys()].sort(), [first, second].sort());
		assert.equal(current.approvals.pendingForFocused().length, 2);
		assert.equal(current.approvals.panel.visible, true);
		// A real disconnect/cold recovery must retain two independently usable IDs.
		current.stop();
		current = await boot();
		assert.deepEqual([...current.store.approvals.keys()].sort(), [first, second].sort());
		assert.equal(current.approvals.panel.visible, true);
		await current.approvals.resolve(first, "approve_once");
		await current.sessions.resync();
		assert.deepEqual([...current.store.approvals.keys()], [second]);
		assert.equal(current.approvals.pendingForFocused()[0]?.event.approvalId, second);
		assert.equal(renderPlain(current.approvalContainer.render(100)).includes("approval-b"), true);
		const policies = (await current.methods.approvalsGet()) as { pending: ExecPendingApproval[] };
		assert.deepEqual(
			policies.pending.map((row) => row.id),
			[second],
		);
		await current.sessions.resync();
		assert.deepEqual([...current.store.approvals.keys()], [second]);
		await current.approvals.resolve(second, "deny");
		await current.sessions.resync();
		assert.equal(current.store.pendingApprovals, 0);
		console.log(
			JSON.stringify({
				status: "passed",
				recoveredPending: 2,
				oneDecisionPreservesOther: true,
				transport: "production_authenticated_loopback_ws",
				providerNetworkCalls: 0,
				browserCalls: 0,
			}),
		);
	} finally {
		app?.stop();
		resetTheme();
		invalidateThemeAdapters();
	}
}

try {
	await run();
} catch {
	// Never print arbitrary RPC errors or token-bearing frames.
	console.error("Approval recovery AppShell smoke failed; no passing evidence claimed.");
	process.exitCode = 1;
}
