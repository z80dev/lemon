import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

const bundleId = "daily-note";
const profileId = "operator";
const digestA = "a".repeat(64);
const digestB = "b".repeat(64);
const planted = "PLANTED_BLUEPRINT_PRIVATE_VALUE";
const privatePath = `/private/${planted}/bundle`;

let harness: Harness;

beforeEach(async () => {
	initTheme({ colorLevel: 3 });
	harness = await createHarness();
});

afterEach(() => {
	harness.stop();
	resetTheme();
	invalidateThemeAdapters();
});

describe("portable blueprint catalog", () => {
	test("/blueprints renders only bounded IDs and counts, then inspects the selection", async () => {
		harness.server.respondWith("blueprints.list", catalogPayload());
		harness.server.respondWith("blueprints.inspect", inspectPayload(false));

		await harness.run("/blueprints");

		expect(harness.server.requestsFor("blueprints.list")).toHaveLength(1);
		const picker = harness.host.pickers[0]!;
		expect(picker.title).toBe("automation blueprints · 1");
		expect(picker.items).toEqual([
			{ value: bundleId, label: bundleId, description: "1 skill · 1 automation" },
		]);
		refutePrivate(JSON.stringify(picker));

		await picker.onSelect(picker.items[0]!);
		expect(harness.server.requestsFor("blueprints.inspect")[0]?.params).toEqual({ bundleId });
		expect(harness.host.text).toContain(`blueprint ${bundleId} · inspected`);
		expect(harness.host.text).toContain("content, schedules, paths, commands");
		refutePrivate(harness.host.text);
	});

	test("filtering is local and invalid catalog rows are never rendered", async () => {
		harness.server.respondWith("blueprints.list", {
			bundles: [
				...catalogPayload().bundles,
				{ id: "../escape", name: planted, skills: [], automations: [] },
			],
			summary: { bundleCount: 2 },
		});

		await harness.run("/blueprints daily");
		expect(harness.server.requestsFor("blueprints.list")[0]?.params).toEqual({});
		expect(harness.host.pickers[0]?.items.map((item) => item.value)).toEqual([bundleId]);
		refutePrivate(JSON.stringify(harness.host.pickers));
	});

	test("inspect and validate discard manifest prose and render allowlisted validation", async () => {
		harness.server.respondWith("blueprints.inspect", inspectPayload(false));
		harness.server.respondWith("blueprints.validate", inspectPayload(true));

		await harness.run(`/blueprint inspect ${bundleId}`);
		await harness.run("/blueprint validate");

		expect(harness.server.requestsFor("blueprints.validate")[0]?.params).toEqual({ bundleId });
		expect(harness.host.text).toContain("validation pass · audit pass · trust untrusted");
		refutePrivate(harness.host.text);
	});

	test("forged IDs fail before a request and raw server errors stay redacted", async () => {
		await harness.run("/blueprint inspect ../escape");
		expect(harness.server.requestsFor("blueprints.inspect")).toHaveLength(0);
		expect(harness.host.last?.text).toBe(
			"blueprint request was refused; use bounded bundle and profile IDs",
		);

		harness.server.failWith(
			"blueprints.inspect",
			"INTERNAL_ERROR",
			`${planted} Bearer secret-token ${privatePath}`,
			{ prompt: planted, path: privatePath },
		);
		await harness.run(`/blueprint inspect ${bundleId}`);
		expect(harness.host.last?.text).toBe("blueprint operation failed safely");
		refutePrivate(harness.host.text);
	});
});

describe("preview and exact activation", () => {
	test("preview is non-mutating and renders only the safe plan projection", async () => {
		harness.server.respondWith("blueprints.preview", previewPayload(digestA, "create"));

		await harness.run(`/blueprint preview ${bundleId} --profile ${profileId}`);

		expect(harness.server.requestsFor("blueprints.preview")[0]?.params).toEqual({
			bundleId,
			profileId,
		});
		expect(harness.server.requestsFor("blueprints.activate")).toHaveLength(0);
		expect(harness.host.text).toContain("preview only · ready · nothing changed");
		expect(harness.host.text).toContain(`confirmation digest: ${digestA}`);
		expect(harness.host.text).toContain("automation cron_daily-note_operator · create · disabled");
		refutePrivate(harness.host.text);
	});

	test("wrong or stale digest causes no mutation, clears the plan, and keeps profile draft", async () => {
		let calls = 0;
		harness.server.onMethod("blueprints.preview", () => {
			calls += 1;
			return previewPayload(calls === 1 ? digestA : digestB, "create");
		});

		await harness.run(`/blueprint preview ${bundleId} --profile ${profileId}`);
		await harness.run(`/blueprint activate ${bundleId} --confirm ${digestA}`);

		expect(harness.server.requestsFor("blueprints.activate")).toHaveLength(0);
		expect(harness.host.text).toContain("activation refused: the exact plan changed");
		expect(harness.host.text).toContain("profile draft kept");

		await harness.run(`/blueprint preview ${bundleId}`);
		expect(harness.server.requestsFor("blueprints.preview").at(-1)?.params).toEqual({
			bundleId,
			profileId,
		});
		refutePrivate(harness.host.text);
	});

	test("exact fresh digest creates once and a fresh unchanged plan replays safely", async () => {
		let action = "create";
		let digest = digestA;
		harness.server.onMethod("blueprints.preview", () => previewPayload(digest, action));
		harness.server.onMethod("blueprints.activate", () => activationPayload(action));

		await harness.run(`/blueprint preview ${bundleId} --profile ${profileId}`);
		await harness.run(`/blueprint activate ${bundleId} --confirm ${digestA}`);

		expect(harness.server.requestsFor("blueprints.activate")[0]?.params).toEqual({
			bundleId,
			profileId,
			confirmationDigest: digestA,
		});
		expect(harness.host.text).toContain("activation created");

		action = "unchanged";
		digest = digestB;
		await harness.run(`/blueprint preview ${bundleId}`);
		await harness.run(`/blueprint activate ${bundleId} --confirm ${digestB}`);

		expect(harness.server.requestsFor("blueprints.activate")).toHaveLength(2);
		expect(harness.host.text).toContain("activation unchanged");
		expect(harness.host.text).toContain("no duplicate created");
		refutePrivate(harness.host.text);
	});

	test("activation failures clear pending confirmation and never echo daemon details", async () => {
		harness.server.respondWith("blueprints.preview", previewPayload(digestA, "create"));
		harness.server.failWith(
			"blueprints.activate",
			"CONFLICT",
			`${planted} prompt command env token ${privatePath}`,
		);

		await harness.run(`/blueprint preview ${bundleId} --profile ${profileId}`);
		await harness.run(`/blueprint activate ${bundleId} --confirm ${digestA}`);

		expect(harness.host.last?.text).toContain("exact plan changed or collided");
		expect(harness.host.last?.text).toContain("profile draft kept");
		refutePrivate(harness.host.text);
	});

	test("malformed replies fail closed without rendering planted fields", async () => {
		harness.server.respondWith("blueprints.preview", {
			...previewPayload(digestA, "create"),
			bundleId: planted,
			prompt: planted,
		});

		await harness.run(`/blueprint preview ${bundleId} --profile ${profileId}`);

		expect(harness.host.last?.text).toBe(
			"blueprint request was refused; use bounded bundle and profile IDs",
		);
		refutePrivate(harness.host.text);
	});

	test("help and completion make the guarded workflow discoverable", async () => {
		expect(harness.registry.has("blueprints")).toBe(true);
		expect(harness.registry.has("blueprint")).toBe(true);
		expect(harness.registry.names()).toContain("blueprints");

		await harness.run("/blueprint help");
		expect(harness.host.text).toContain("/blueprint preview [bundle-id] --profile <profile-id>");
		expect(harness.host.text).toContain("requires an exact fresh digest");
	});
});

function catalogPayload() {
	return {
		bundles: [inspectPayload(false)],
		summary: {
			bundleCount: 1,
			invalidBundleCount: 0,
			pathsReturned: false,
			privatePath,
		},
	};
}

function inspectPayload(validated: boolean) {
	return {
		id: bundleId,
		name: `${planted} private name`,
		description: `${planted} private description`,
		manifestDigest: "c".repeat(64),
		skills: [
			{
				key: "safe-note",
				path: privatePath,
				name: planted,
				body: `${planted} skill body`,
			},
		],
		automations: [
			{
				id: "daily-note",
				name: planted,
				schedule: "0 0 1 1 *",
				prompt: `${planted} prompt`,
				command: `${planted} command`,
				env: { SECRET_TOKEN: planted },
				enabled: false,
			},
		],
		validation: {
			valid: true,
			validationRequested: validated,
			auditStatus: "pass",
			trustLevel: "untrusted",
		},
		summary: { skillCount: 1, automationCount: 1 },
	};
}

function previewPayload(digest: string, action: string) {
	return {
		bundleId,
		profile: {
			id: profileId,
			canonicalSessionKey: `agent:${profileId}:main`,
			workspace: privatePath,
		},
		confirmationDigest: digest,
		canActivate: true,
		skills: [
			{
				key: "safe-note",
				action: action === "create" ? "create" : "unchanged",
				fileCount: 1,
				bytes: 42,
				body: `${planted} skill body`,
				path: privatePath,
			},
		],
		automation: {
			id: "cron_daily-note_operator",
			action,
			enabled: false,
			schedule: "0 0 1 1 *",
			prompt: `${planted} prompt`,
			command: `${planted} command`,
			env: { TOKEN: planted },
		},
	};
}

function activationPayload(status: string) {
	return {
		activated: true,
		bundleId,
		profileId,
		confirmationDigest: status === "created" ? digestA : digestB,
		skills: [
			{ key: "safe-note", status: status === "create" ? "created" : "unchanged", body: planted },
		],
		automation: {
			id: "cron_daily-note_operator",
			status: status === "create" ? "created" : "unchanged",
			prompt: planted,
		},
		summary: { prompt: planted, path: privatePath },
	};
}

function refutePrivate(text: string): void {
	expect(text).not.toContain(planted);
	expect(text).not.toContain(privatePath);
	expect(text).not.toContain("Bearer secret-token");
}
