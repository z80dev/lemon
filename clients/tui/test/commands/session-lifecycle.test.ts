import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { lstatSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

let harness: Harness;
let workdir: string;

const sessionKey = "agent:research:main";

const session = {
	sessionKey,
	agentId: "research",
	origin: "tui",
	createdAtMs: 1_000,
	updatedAtMs: 2_000,
	runCount: 3,
	title: "Launch room",
	pinned: true,
	archived: false,
	model: "openai:gpt-5",
};

beforeEach(async () => {
	initTheme({ colorLevel: 3 });
	workdir = mkdtempSync(join(tmpdir(), "lemon-tui-sessions-"));
	harness = await createHarness({ sessionKey: "tui-session", cwd: workdir });
});

afterEach(() => {
	harness.stop();
	rmSync(workdir, { recursive: true, force: true });
	resetTheme();
	invalidateThemeAdapters();
});

describe("session discovery and inspection", () => {
	test("/sessions sends bounded filters and renders only lifecycle metadata", async () => {
		harness.host.draft = "unfinished user draft";
		harness.server.respondWith("sessions.list", {
			sessions: [
				{
					...session,
					prompt: "do not render this prompt",
					workspace: "/private/server/path",
					credential: "raw-list-secret",
				},
			],
			total: 1,
		});

		await harness.run('/sessions "launch plan" --pinned --active --agent research --limit 5');

		expect(harness.server.requestsFor("sessions.list")[0]?.params).toEqual({
			query: "launch plan",
			pinned: true,
			archived: false,
			agentId: "research",
			limit: 5,
		});
		const picker = harness.host.pickers[0]!;
		expect(picker.title).toBe("session search");
		expect(picker.items[0]?.label).toContain("Launch room");
		expect(picker.items[0]?.description).toContain("pinned");
		const rendered = JSON.stringify(picker.items);
		expect(rendered).not.toContain("do not render this prompt");
		expect(rendered).not.toContain("/private/server/path");
		expect(rendered).not.toContain("raw-list-secret");
		expect(harness.host.draft).toBe("unfinished user draft");
	});

	test("conflicting and oversized search filters are rejected before the wire", async () => {
		await harness.run("/sessions query --pinned --unpinned");
		await harness.run(`/session search ${"x".repeat(513)}`);

		expect(harness.server.requestsFor("sessions.list")).toHaveLength(0);
		expect(harness.host.text).toContain("do not combine --pinned and --unpinned");
		expect(harness.host.text).toContain("at most 512 bytes");
	});

	test("show/current reports safe metadata without prompt, workspace, or response extras", async () => {
		harness.server.respondWith("sessions.list", {
			sessions: [
				{
					...session,
					prompt: "private prompt",
					answer: "private answer",
					workspaceDir: "/private/project",
				},
			],
		});

		await harness.run(`/session show ${sessionKey}`);

		expect(harness.host.text).toContain("Launch room");
		expect(harness.host.text).toContain("runs: 3");
		expect(harness.host.text).not.toContain("private prompt");
		expect(harness.host.text).not.toContain("private answer");
		expect(harness.host.text).not.toContain("/private/project");
	});

	test("open verifies an exact durable key before asking the host to switch", async () => {
		const switched: string[] = [];
		(
			harness.host as typeof harness.host & {
				switchSession(key: string): void;
			}
		).switchSession = (key: string) => {
			switched.push(key);
		};
		harness.server.respondWith("sessions.list", { sessions: [session] });

		await harness.run(`/session open ${sessionKey}`);

		expect(harness.server.requestsFor("sessions.list")[0]?.params).toEqual({
			query: sessionKey,
			limit: 500,
		});
		expect(switched).toEqual([sessionKey]);
	});
});

describe("session metadata and resume", () => {
	test("title and flags use redaction-safe metadata responses", async () => {
		const title = "Confidential release title";
		harness.server.onMethod("sessions.metadata.patch", (params: Record<string, unknown>) => ({
			success: true,
			sessionKey: params.sessionKey,
			metadata: {
				titlePresent: params.title !== null,
				titleBytes: typeof params.title === "string" ? Buffer.byteLength(params.title) : 0,
				pinned: params.pinned === true,
				archived: params.archived === true,
			},
		}));

		await harness.run(`/session title ${sessionKey} "${title}"`);
		await harness.run(`/session pin ${sessionKey}`);
		await harness.run(`/session archive ${sessionKey}`);
		await harness.run(`/session unpin ${sessionKey}`);
		await harness.run(`/session unarchive ${sessionKey}`);

		const requests = harness.server.requestsFor("sessions.metadata.patch");
		expect(requests.map((request) => request.params)).toEqual([
			{ sessionKey, title },
			{ sessionKey, pinned: true },
			{ sessionKey, archived: true },
			{ sessionKey, pinned: false },
			{ sessionKey, archived: false },
		]);
		expect(harness.host.text).not.toContain(title);
		expect(harness.host.text).toContain("title updated");
		expect(harness.host.text).toContain("unarchived");
	});

	test("resume verifies the durable key and replays only after success", async () => {
		harness.store.setFocused(sessionKey);
		harness.server.respondWith("sessions.list", { sessions: [session] });
		harness.server.respondWith("chat.history", {
			sessionKey,
			messages: [{ id: "m1", role: "user", content: "explicit resume content" }],
		});

		await harness.run(`/session resume ${sessionKey} 25`);

		expect(harness.server.requestsFor("chat.history")[0]?.params).toEqual({
			sessionKey,
			limit: 25,
			includeFullText: true,
		});
		expect(harness.host.replays).toHaveLength(1);
	});

	test("preview displays only the server-redacted bounded fields", async () => {
		harness.server.respondWith("sessions.preview", {
			sessionKey,
			preview: [
				{
					runId: "run-1",
					prompt: "api_key=[REDACTED]",
					answer: "Bearer [REDACTED]",
					ok: true,
					timestampMs: 1000,
					rawProviderPayload: "never-render-this",
				},
			],
		});

		await harness.run(`/session preview ${sessionKey} 1`);

		expect(harness.host.text).toContain("api_key=[REDACTED]");
		expect(harness.host.text).toContain("Bearer [REDACTED]");
		expect(harness.host.text).not.toContain("never-render-this");
	});
});

describe("redacted export and guarded deletion", () => {
	test("export verifies digest and writes a private file without reporting the raw path", async () => {
		const content = '{"prompt":"api_key=[REDACTED]"}\n';
		const output = join(workdir, "nested", "session.json");
		harness.server.respondWith("sessions.export", exportResult(content, "json"));

		await harness.run(`/session export ${sessionKey} json --output ${output}`);

		expect(readFileSync(output, "utf8")).toBe(content);
		expect(lstatSync(output).mode & 0o777).toBe(0o600);
		expect(harness.host.text).toContain("session.json");
		expect(harness.host.text).not.toContain(workdir);
	});

	test("digest mismatch and unsafe destinations fail closed without leaking details", async () => {
		const output = join(workdir, "secret-output.json");
		const target = join(workdir, "target.json");
		writeFileSync(target, "keep");
		symlinkSync(target, output);
		harness.server.respondWith("sessions.export", {
			...exportResult("api_key=[REDACTED]\n", "json"),
			sha256: "0".repeat(64),
		});

		await harness.run(`/session export ${sessionKey} json --output ${output} --force`);

		expect(readFileSync(target, "utf8")).toBe("keep");
		expect(harness.host.text).toContain("did not complete (LOCAL_VALIDATION)");
		expect(harness.host.text).not.toContain(workdir);
	});

	test("an oversized export is rejected before any file is created", async () => {
		const content = "x".repeat(750_001);
		const output = join(workdir, "oversized.json");
		harness.server.respondWith("sessions.export", exportResult(content, "json"));

		await harness.run(`/session export ${sessionKey} json --output ${output}`);

		expect(() => lstatSync(output)).toThrow();
		expect(harness.host.text).toContain("did not complete (LOCAL_VALIDATION)");
		expect(harness.host.text).not.toContain(workdir);
	});

	test("delete previews first, requires the exact key, then exports before verified deletion", async () => {
		const content = "# Redacted session\n\napi_key=[REDACTED]\n";
		const output = join(workdir, "before-delete.md");
		harness.server.respondWith("sessions.list", { sessions: [session] });
		harness.server.respondWith("sessions.export", exportResult(content, "markdown"));
		harness.server.respondWith("sessions.delete", {
			deleted: true,
			sessionKey,
			summary: { existed: true, verified: true },
		});

		await harness.run(`/session delete ${sessionKey}`);
		expect(harness.server.requestsFor("sessions.delete")).toHaveLength(0);
		expect(harness.host.text).toContain(`--confirm ${sessionKey}`);

		await harness.run(`/session delete ${sessionKey} --confirm wrong`);
		expect(harness.server.requestsFor("sessions.delete")).toHaveLength(0);

		await harness.run(
			`/session delete ${sessionKey} --confirm ${sessionKey} --export markdown --output ${output}`,
		);

		expect(readFileSync(output, "utf8")).toBe(content);
		expect(harness.server.requestsFor("sessions.export")).toHaveLength(1);
		expect(harness.server.requestsFor("sessions.delete")).toHaveLength(1);
		expect(harness.host.forgottenSessions).toEqual([sessionKey]);
		expect(harness.host.text).toContain("verified deletion");
	});

	test("refused deletion reports only the stable error code", async () => {
		harness.host.draft = "draft survives refused mutation";
		harness.server.respondWith("sessions.list", { sessions: [session] });
		harness.server.failWith(
			"sessions.delete",
			"CONFLICT",
			"candidate moved /private/path token=raw-server-secret",
		);

		await harness.run(`/session delete ${sessionKey} --confirm ${sessionKey}`);

		expect(harness.host.text).toContain("(CONFLICT)");
		expect(harness.host.text).not.toContain("/private/path");
		expect(harness.host.text).not.toContain("raw-server-secret");
		expect(harness.host.forgottenSessions).toHaveLength(0);
		expect(harness.host.draft).toBe("draft survives refused mutation");
	});
});

describe("exact preview-confirm pruning", () => {
	test("preview and execution preserve the exact cutoff, widening flags, token, and candidates", async () => {
		const cutoff = 1_700_000_000_000;
		const token = "a".repeat(64);
		const candidates = ["agent:old-a:main", "agent:old-b:main"];
		harness.server.onMethod("sessions.prune", (params: Record<string, unknown>) =>
			params.dryRun === false
				? {
						dryRun: false,
						olderThanMs: cutoff,
						archivedOnly: false,
						includePinned: true,
						confirmToken: token,
						candidateSessionKeys: candidates,
						candidateCount: 2,
						deletedSessionKeys: candidates,
						deletedCount: 2,
						verified: true,
					}
				: {
						dryRun: true,
						olderThanMs: cutoff,
						archivedOnly: false,
						includePinned: true,
						confirmToken: token,
						candidateSessionKeys: candidates,
						candidateCount: 2,
						deletedSessionKeys: [],
						deletedCount: 0,
						verified: false,
					},
		);

		await harness.run(`/session prune --older-than ${cutoff} --all --include-pinned`);
		expect(harness.server.requestsFor("sessions.prune")[0]?.params).toEqual({
			olderThanMs: cutoff,
			archivedOnly: false,
			includePinned: true,
			dryRun: true,
		});
		expect(harness.host.text).toContain(candidates[0]);
		expect(harness.host.text).toContain(candidates[1]);
		expect(harness.host.text).toContain(token);

		await harness.run(
			`/session prune --older-than ${cutoff} --all --include-pinned --confirm ${token}`,
		);
		expect(harness.server.requestsFor("sessions.prune")[1]?.params).toEqual({
			olderThanMs: cutoff,
			archivedOnly: false,
			includePinned: true,
			dryRun: false,
			confirmToken: token,
		});
		expect(harness.host.forgottenSessions).toEqual(candidates);
		expect(harness.host.text).toContain("verified prune deleted 2");
	});

	test("a changed candidate set is refused without surfacing daemon details", async () => {
		harness.server.failWith(
			"sessions.prune",
			"CONFLICT",
			"changed /private/store api_key=server-secret",
		);

		await harness.run(`/session prune --older-than 1700000000000 --confirm ${"b".repeat(64)}`);

		expect(harness.host.text).toContain("(CONFLICT)");
		expect(harness.host.text).not.toContain("/private/store");
		expect(harness.host.text).not.toContain("server-secret");
		expect(harness.host.forgottenSessions).toHaveLength(0);
	});
});

function exportResult(content: string, format: "json" | "markdown") {
	return {
		sessionKey,
		format,
		filename: format === "json" ? "session.json" : "session.md",
		content,
		sha256: createHash("sha256").update(content).digest("hex"),
		bytes: Buffer.byteLength(content),
		redacted: true,
		summary: { runCount: 1, cleanup: { includesSecretValues: false } },
	};
}
