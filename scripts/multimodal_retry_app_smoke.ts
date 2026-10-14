// Run from the integrated source checkout: bun scripts/multimodal_retry_app_smoke.ts
// Requires the integration owner's fresh compiled BEAMs; never compiles or uses ExUnit.
import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { AppShell } from "../clients/tui/src/app.ts";
import { DEFAULT_METHODS, FakeControlPlane, errorResult } from "../clients/tui/src/dev/fake-server.ts";
import { ControlPlaneClient } from "../clients/tui/src/protocol/client.ts";
import { newSessionKey } from "../clients/tui/src/session-key.ts";
import { initTheme, resetTheme } from "../clients/tui/src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../clients/tui/src/ui/theme/tui-adapters.ts";
import { MemoryTerminal } from "../clients/tui/test/helpers/memory-terminal.ts";
import { asRecord, pick } from "../clients/tui/src/commands/format.ts";

const root = resolve(import.meta.dir, "..");
const work = await mkdtemp(resolve(tmpdir(), "lemon-multimodal-retry-"));
const backend = Bun.spawn(["mix", "run", "--no-compile", "scripts/multimodal_retry_backend_smoke.exs"], {
	cwd: root,
	stdin: "pipe",
	stdout: "pipe",
	stderr: "inherit",
});
const pending = new Map<number, PromiseWithResolvers<unknown>>();
let nextId = 0;
let ended = false;
const output = (async () => {
	let buffer = "";
	const decoder = new TextDecoder();
	for await (const chunk of backend.stdout) {
		buffer += decoder.decode(chunk, { stream: true });
		for (;;) {
			const end = buffer.indexOf("\n");
			if (end < 0) break;
			const line = buffer.slice(0, end);
			buffer = buffer.slice(end + 1);
			const marker = "MULTIMODAL_RETRY_SMOKE ";
			if (!line.startsWith(marker)) continue;
			const response = asRecord(JSON.parse(line.slice(marker.length)));
			assert.ok(response && typeof response.id === "number");
			pending.get(response.id)?.resolve(response.result);
			pending.delete(response.id);
		}
	}
	ended = true;
	for (const waiter of pending.values()) waiter.reject(new Error("source backend exited without a receipt"));
	pending.clear();
})();

async function sourceBackend(method: string, params: unknown): Promise<unknown> {
	assert.equal(ended, false, "source backend must remain alive");
	const id = ++nextId;
	const receipt = Promise.withResolvers<unknown>();
	pending.set(id, receipt);
	backend.stdin.write(`${JSON.stringify({ id, method, params })}\n`);
	await backend.stdin.flush();
	return await receipt.promise;
}

async function wire(method: string, params: unknown) {
	const receipt = asRecord(await sourceBackend(method, params));
	assert.ok(receipt, "source receipt must be an object");
	const result = asRecord(receipt.ok);
	assert.ok(result, `${method} failed: ${JSON.stringify(receipt.error)}`);
	return result;
}

initTheme({ colorLevel: 3 });
try {
	for (const kind of ["mixed", "separate", "unknown", "text", "text-unknown", "text-late-focus"] as const) {
		for (const command of ["/retry", "/retry --force"]) {
			const cwd = resolve(work, `${kind}-${command.endsWith("force") ? "forced" : "normal"}`);
			await mkdir(cwd, { recursive: true });
			const key = newSessionKey(cwd);
			const media = !kind.startsWith("text");
			const seed = asRecord(await sourceBackend("seed", { kind: media ? kind : "text", cwd, sessionKey: key }));
			assert.ok(seed && typeof seed.entryId === "string" && typeof seed.prompt === "string");
			const before = await sourceBackend("snapshot", {});
			const target = { sessionKey: key, cwd, entryId: seed.entryId, restoreFiles: false, allowPartialRestore: false };
			const preview = await wire("sessions.rewind", { ...target, dryRun: true });
			assert.equal(preview.promptContainsNonText, media);
			assert.equal(preview.prompt, seed.prompt);
			assert.deepEqual(await sourceBackend("snapshot", {}), before, "real preview must not mutate the journal");

			const server = await FakeControlPlane.start({ methods: [...DEFAULT_METHODS, "sessions.tree", "sessions.rewind"] });
			server.respondWith("sessions.active.list", { sessions: [] });
			server.respondWith("exec.approvals.get", { approvals: [] });
			server.respondWith("sessions.list", { sessions: [], total: 0 });
			for (const method of ["chat.history", "sessions.tree", "sessions.rewind"]) {
				server.onMethod(method, (params: unknown) => wire(method, params));
			}
			// Only send receipts are scripted; history/tree/rewind are native source methods.
			server.onMethod("chat.send", () => kind === "text-unknown"
				? errorResult("UNAVAILABLE", "receipt lost", { retrySafe: false, runId: "possibly-accepted" })
				: { sessionKey: key, runId: "smoke-retry-run" });
			const terminal = new MemoryTerminal();
			const app = new AppShell({ url: server.url, cwd, sessionKey: key, terminal,
				client: new ControlPlaneClient({ url: server.url }), readBranch: async () => null });
			try {
				await app.start();
				app.session.lastRunOutcome = "error";
				const originalTranscript = app.session.blocks.filter((block) => block.kind !== "notice");
				assert.ok(originalTranscript.some((block) => block.kind === "user" && block.text === seed.prompt), "AppShell must hydrate the real stored text projection");
				app.editor.setText("preserve correction");
				app.store.setDraft(key, "preserve correction");
				if (kind === "text-late-focus") {
					server.onMethod("chat.history", async (params: unknown) => {
						const receipt = await wire("chat.history", params);
						app.store.setFocused("other");
						app.editor.setText("other session correction");
						return receipt;
					});
				}
				await app.submit(command);
				const rewinds = server.requestsFor("sessions.rewind");
				if (media) {
					assert.equal(rewinds.length, 1);
					assert.equal(pick(rewinds[0].params, "dryRun"), true);
					assert.equal(server.requestsFor("chat.send").length, 0);
					assert.equal(server.requestsFor("chat.history").length, 1);
					assert.deepEqual(await sourceBackend("snapshot", {}), before, "media refusal must preserve leaf, original bytes and history");
					assert.deepEqual(app.session.blocks.filter((block) => block.kind !== "notice"), originalTranscript);
					assert.equal(app.editor.getExpandedText(), "preserve correction");
					assert.equal(app.store.drafts.get(key), "preserve correction");
					assert.equal(app.store.queue.items(key).length, 0);
				} else {
					assert.equal(rewinds.length, 2);
					assert.equal(pick(rewinds[1].params, "dryRun"), false);
					const after = asRecord(await sourceBackend("snapshot", {}));
					assert.ok(after, "snapshot must be an object");
					assert.equal(after.leafId, null, "text retry must confirm an actual native rewind");
					assert.equal(pick(after, "entries"), pick(before, "entries"), "abandoned branch must remain durable");
					assert.deepEqual(pick(after, "message"), pick(before, "message"));
					if (kind === "text-late-focus") {
						assert.equal(server.requestsFor("chat.send").length, 0);
						assert.equal(app.store.focusedKey, "other");
						assert.equal(app.store.drafts.get(key), seed.prompt);
						assert.equal(app.editor.getExpandedText(), "other session correction");
					} else {
						assert.equal(server.requestsFor("chat.send").length, 1);
						assert.equal(pick(server.requestsFor("chat.send")[0].params, "prompt"), seed.prompt);
						if (kind === "text-unknown") {
							const item = app.store.queue.items(key)[0];
							assert.equal(item.state, "needs-review");
							assert.equal(item.submission?.requestId, server.requestsFor("chat.send")[0].id);
							assert.equal(item.submission?.runId, "possibly-accepted");
							assert.equal(app.editor.getExpandedText(), seed.prompt);
							assert.equal(app.store.drafts.get(key), seed.prompt);
							await app.drainQueue(key);
							await app.submit("/retry --force");
							assert.equal(server.requestsFor("chat.send").length, 1);
							assert.equal(server.requestsFor("sessions.rewind").length, 2);
							assert.equal(app.store.queue.items(key)[0], item);
						} else {
							assert.equal(app.editor.getExpandedText(), "");
							assert.equal(app.session.activeRunId, "smoke-retry-run");
						}
					}
				}
			} finally {
				app.stop();
				server.stop();
			}
			console.log(`PASS ${kind} ${command}: actual AppShell + source preview/history/rewind`);
		}
	}

	// The same preview's token must be invalidated by a real later journal turn.
	const cwd = resolve(work, "revision");
	await mkdir(cwd, { recursive: true });
	const key = newSessionKey(cwd);
	const seed = asRecord(await sourceBackend("seed", { kind: "mixed", cwd, sessionKey: key }));
	assert.ok(seed && typeof seed.entryId === "string");
	const target = { sessionKey: key, cwd, entryId: seed.entryId, restoreFiles: false, allowPartialRestore: false };
	const preview = await wire("sessions.rewind", { ...target, dryRun: true });
	await sourceBackend("append", {});
	const changed = await sourceBackend("snapshot", {});
	const stale = await sourceBackend("sessions.rewind", { ...target, dryRun: false, confirmationToken: preview.confirmationToken });
	assert.equal(pick(stale, "error.details.reason"), "stale_confirmation");
	assert.deepEqual(await sourceBackend("snapshot", {}), changed);
	console.log("PASS original media metadata remains bound to the existing revision token");
} finally {
	backend.stdin.end();
	await output;
	const exit = await backend.exited;
	await rm(work, { recursive: true, force: true });
	resetTheme();
	invalidateThemeAdapters();
	assert.equal(exit, 0, "source backend must terminate cleanly");
}
