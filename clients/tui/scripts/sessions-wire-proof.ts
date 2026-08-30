/**
 * Authenticated real-control-plane proof driver for the TUI session lifecycle.
 *
 * The matching ExUnit test owns the isolated store rows and starts Bandit. This
 * client deliberately uses only the production typed wrappers used by the TUI.
 */

import { createHash } from "node:crypto";
import { ControlPlaneError } from "../src/protocol/errors.ts";
import { ControlPlaneClient } from "../src/protocol/client.ts";
import { ControlPlaneMethods } from "../src/protocol/methods.ts";

const [url, token, pruneKey, deleteKey, keepKey, cutoffRaw, secret] = process.argv.slice(2);
if (!url || !token || !pruneKey || !deleteKey || !keepKey || !cutoffRaw || !secret) {
	throw new Error(
		"usage: bun sessions-wire-proof.ts <ws-url> <operator-token> <prune-key> <delete-key> <keep-key> <cutoff-ms> <secret>",
	);
}
const cutoff = Number.parseInt(cutoffRaw, 10);
assert(Number.isSafeInteger(cutoff) && cutoff > 0, "valid cutoff");

const client = new ControlPlaneClient({
	url,
	token,
	clientId: "lemon-tui-session-wire-proof",
	requestTimeoutMs: 5_000,
	socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
});
const methods = new ControlPlaneMethods(client);

try {
	const hello = await client.connect();
	assert(hello.auth?.role === "operator", "operator authentication");

	const searched = await methods.sessionsList({
		query: "wire lifecycle",
		archived: false,
		limit: 10,
	});
	assert(searched.sessions?.length === 1, "bounded search result count");
	assert(searched.sessions[0]?.sessionKey === pruneKey, "bounded search exact key");
	assert(JSON.stringify(searched).includes(secret) === false, "search does not return content");

	const resumed = await methods.chatHistory({
		sessionKey: pruneKey,
		limit: 5,
		includeFullText: true,
	});
	assert(resumed.messages.length >= 2, "resume history messages");

	const titled = await methods.sessionsMetadataPatch({
		sessionKey: pruneKey,
		title: "Wire lifecycle room",
	});
	assert(titled.metadata.titlePresent === true, "metadata title present");
	assert(
		JSON.stringify(titled).includes("Wire lifecycle room") === false,
		"metadata title not echoed",
	);
	await methods.sessionsMetadataPatch({ sessionKey: pruneKey, pinned: true });
	await methods.sessionsMetadataPatch({ sessionKey: pruneKey, pinned: false, archived: true });

	const preview = await methods.sessionsPreview({ sessionKey: pruneKey, limit: 2 });
	assert(preview.preview.length === 1, "redacted preview count");
	const previewText = JSON.stringify(preview);
	assert(previewText.includes(secret) === false, "preview secret redacted");
	assert(previewText.includes("[REDACTED]"), "preview redaction marker");

	const jsonExport = await methods.sessionsExport({ sessionKey: pruneKey, format: "json" });
	verifyExport(jsonExport, secret, "json");

	const prunePreview = await methods.sessionsPrune({
		olderThanMs: cutoff,
		archivedOnly: true,
		includePinned: false,
		dryRun: true,
	});
	assert(prunePreview.candidateCount === 1, "prune candidate count");
	assert(
		JSON.stringify(prunePreview.candidateSessionKeys) === JSON.stringify([pruneKey]),
		"prune exact candidate set",
	);
	assert(prunePreview.candidateSessionKeys.includes(keepKey) === false, "fresh session excluded");

	let changedSetRefused = false;
	try {
		await methods.sessionsPrune({
			olderThanMs: cutoff - 1,
			archivedOnly: true,
			includePinned: false,
			dryRun: false,
			confirmToken: prunePreview.confirmToken,
		});
	} catch (error) {
		changedSetRefused = ControlPlaneError.is(error, "CONFLICT");
	}
	assert(changedSetRefused, "changed prune parameters refused");

	const pruned = await methods.sessionsPrune({
		olderThanMs: cutoff,
		archivedOnly: true,
		includePinned: false,
		dryRun: false,
		confirmToken: prunePreview.confirmToken,
	});
	assert(pruned.verified === true, "prune verified");
	assert(
		JSON.stringify(pruned.deletedSessionKeys) === JSON.stringify([pruneKey]),
		"prune deleted exact preview set",
	);

	const markdownExport = await methods.sessionsExport({
		sessionKey: deleteKey,
		format: "markdown",
	});
	verifyExport(markdownExport, secret, "markdown");
	const deleted = await methods.sessionsDelete({ sessionKey: deleteKey });
	assert(deleted.deleted === true, "single delete committed");
	assert(deleted.summary?.verified === true, "single delete verified");

	const remaining = await methods.sessionsList({ limit: 10 });
	assert(
		remaining.sessions?.some((row) => row.sessionKey === keepKey),
		"fresh session retained",
	);
	assert(remaining.sessions?.some((row) => row.sessionKey === pruneKey) === false, "pruned absent");
	assert(
		remaining.sessions?.some((row) => row.sessionKey === deleteKey) === false,
		"deleted absent",
	);

	console.log(
		JSON.stringify({
			ok: true,
			checks: [
				"authenticated_handshake",
				"bounded_search",
				"resume_history",
				"metadata_mutations",
				"redacted_json_markdown_export",
				"exact_candidate_prune",
				"verified_delete_after_export",
			],
			candidateCount: prunePreview.candidateCount,
			deletedCount: pruned.deletedCount + (deleted.deleted ? 1 : 0),
		}),
	);
} finally {
	client.close();
}

function verifyExport(
	exported: {
		format: string;
		content: string;
		sha256: string;
		bytes: number;
		redacted: true;
	},
	secretValue: string,
	format: string,
): void {
	assert(exported.format === format, `${format} export format`);
	assert(exported.redacted === true, `${format} export redacted flag`);
	assert(exported.content.includes(secretValue) === false, `${format} export secret redacted`);
	assert(exported.content.includes("[redacted]"), `${format} export redaction marker`);
	assert(Buffer.byteLength(exported.content) === exported.bytes, `${format} export byte count`);
	assert(
		createHash("sha256").update(exported.content).digest("hex") === exported.sha256,
		`${format} export digest`,
	);
}

function assert(condition: unknown, label: string): asserts condition {
	if (!condition) throw new Error(`session wire proof failed: ${label}`);
}
