/**
 * Authenticated real-control-plane proof for TUI blueprint management.
 *
 * This drives the production typed client and slash-command registry. The
 * matching ExUnit test owns an isolated catalog, profile, store, and Bandit
 * listener, then verifies the resulting skill/job state server-side.
 */

import type { CommandHost, PickerSpec } from "../src/commands/index.ts";
import { createCommandRegistry } from "../src/commands/index.ts";
import { ControlPlaneClient } from "../src/protocol/client.ts";
import { ControlPlaneMethods } from "../src/protocol/methods.ts";
import { AppStore } from "../src/store/app-store.ts";
import type { NoticeLevel } from "../src/store/transcript-model.ts";

const [url, token, bundleId, profileId, planted, privateRoot] = process.argv.slice(2);
if (!url || !token || !bundleId || !profileId || !planted || !privateRoot) {
	throw new Error(
		"usage: bun blueprints-wire-proof.ts <ws-url> <operator-token> <bundle-id> <profile-id> <planted-value> <private-root>",
	);
}

class ProofHost implements CommandHost {
	readonly notices: Array<{ text: string; level: NoticeLevel }> = [];
	readonly pickers: PickerSpec[] = [];

	notice(text: string, level: NoticeLevel = "info"): void {
		this.notices.push({ text, level });
	}
	noticeBlock(lines: string[], level: NoticeLevel = "info"): void {
		this.notice(lines.join("\n"), level);
	}
	clearTranscript(): void {}
	requestExit(_code: number): void {}
	reconnect(): void {}
	refreshStatus(): void {}
	getDraft(): string {
		return "";
	}
	setDraft(_text: string): void {}
	openPicker(spec: PickerSpec): void {
		this.pickers.push(spec);
	}
	openMultiPicker(): void {}
	closeOverlay(): void {}
	frameLog(): readonly string[] {
		return [];
	}
	replayHistory(): void {}

	get text(): string {
		return this.notices.map((notice) => notice.text).join("\n");
	}

	lastText(): string {
		return this.notices.at(-1)?.text ?? "";
	}
}

const client = new ControlPlaneClient({
	url,
	token,
	clientId: "lemon-tui-blueprint-wire-proof",
	requestTimeoutMs: 5_000,
	socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
});
const methods = new ControlPlaneMethods(client);
const store = new AppStore("tui-blueprint-wire");
const host = new ProofHost();
const registry = createCommandRegistry();
const dispatch = (line: string) =>
	registry.dispatch(line, {
		store,
		session: store.focused,
		methods,
		client,
		ui: host,
	});

try {
	const hello = await client.connect();
	assert(hello.auth?.role === "operator", "operator authentication");

	await dispatch("/blueprints");
	const picker = host.pickers.at(-1);
	assert(picker?.items.length === 1, "bounded catalog picker");
	assert(picker?.items[0]?.value === bundleId, "catalog bundle id");
	await picker?.onSelect(picker.items[0]!);
	assert(host.lastText().includes(`blueprint ${bundleId} · inspected`), "picker inspection");

	await dispatch(`/blueprint validate ${bundleId}`);
	assert(host.lastText().includes("validation pass"), "content-free validation");

	await dispatch(`/blueprint preview ${bundleId} --profile ${profileId}`);
	let previewText = host.lastText();
	assert(previewText.includes("preview only · ready · nothing changed"), "non-mutating preview");
	assert(previewText.includes(" · create · "), "initial create plan");
	const createDigest = extractDigest(previewText);

	await dispatch(
		`/blueprint activate ${bundleId} --profile ${profileId} --confirm ${"0".repeat(64)}`,
	);
	assert(host.lastText().includes("activation refused"), "wrong digest refusal");
	await dispatch(`/blueprint preview ${bundleId} --profile ${profileId}`);
	assert(host.lastText().includes(" · create · "), "wrong digest caused no mutation");

	await dispatch(
		`/blueprint activate ${bundleId} --profile ${profileId} --confirm ${createDigest}`,
	);
	assert(host.lastText().includes("activation created"), "exact activation create");

	await dispatch(`/blueprint preview ${bundleId} --profile ${profileId}`);
	previewText = host.lastText();
	assert(previewText.includes(" · unchanged · "), "replay unchanged plan");
	const replayDigest = extractDigest(previewText);
	await dispatch(
		`/blueprint activate ${bundleId} --profile ${profileId} --confirm ${replayDigest}`,
	);
	assert(host.lastText().includes("activation unchanged"), "duplicate-safe replay");
	assert(host.lastText().includes("no duplicate created"), "duplicate-safe receipt");

	const rendered = host.text;
	assert(!rendered.includes(planted), "planted content absent");
	assert(!rendered.includes(privateRoot), "private root absent");
	assert(!rendered.includes(token), "operator token absent");
	assert(!rendered.includes("Bearer "), "bearer value absent");

	console.log(
		JSON.stringify({
			ok: true,
			checks: [
				"authenticated_handshake",
				"content_free_catalog_inspect_validate",
				"preview_no_mutation",
				"wrong_digest_no_mutation",
				"exact_activation",
				"duplicate_safe_replay",
				"planted_content_absent",
			],
			created: true,
			replay: "unchanged",
		}),
	);
} finally {
	client.close();
}

function extractDigest(text: string): string {
	const match = text.match(/confirmation digest: ([a-f0-9]{64})/);
	assert(match?.[1], "confirmation digest");
	return match[1];
}

function assert(condition: unknown, label: string): asserts condition {
	if (!condition) throw new Error(`blueprint wire proof failed: ${label}`);
}
