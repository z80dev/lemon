import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

let harness: Harness;

const research = {
	id: "research",
	name: "Research",
	description: "Evidence-first research specialist",
	model: "openai:gpt-5",
	node: "newphy",
	canonicalSessionKey: "agent:research:main",
	availability: "online",
	workspace: "/private/server-owned/workspace",
};

beforeEach(async () => {
	initTheme({ colorLevel: 3 });
	harness = await createHarness({ sessionKey: "tui-session" });
	harness.server.respondWith("profiles.roster", {
		profiles: [research],
		count: 1,
		availabilityCounts: { online: 1 },
	});
	harness.server.respondWith("profiles.get", { profile: research });
});

afterEach(() => {
	harness.stop();
	resetTheme();
	invalidateThemeAdapters();
});

describe("profile discovery and canonical chat", () => {
	test("/profiles renders a path-free roster picker and opens its canonical chat", async () => {
		await harness.run("/profiles");

		expect(harness.server.requestsFor("profiles.roster")).toHaveLength(1);
		const picker = harness.host.pickers[0]!;
		expect(picker.title).toBe("profiles");
		expect(picker.items[0]).toMatchObject({
			value: "research",
			label: "Research (research)",
		});
		expect(picker.items[0]?.description).toContain("newphy · online");
		expect(JSON.stringify(picker.items)).not.toContain("/private/server-owned/workspace");

		await picker.onSelect(picker.items[0]!);
		expect(harness.host.profileOpens).toEqual([
			{ profileId: "research", sessionKey: "agent:research:main" },
		]);
	});

	test("/profile current names the stable route when focused on a profile", async () => {
		harness.store.setFocused("agent:research:main");
		await harness.run("/profile current");

		expect(harness.host.text).toContain("Research (research) · current");
		expect(harness.host.text).toContain("newphy (online)");
		expect(harness.host.text).toContain("agent:research:main");
	});

	test("/profile open verifies the id through profiles.get", async () => {
		await harness.run("/profile open research");

		expect(harness.server.requestsFor("profiles.get")[0]?.params).toEqual({ id: "research" });
		expect(harness.host.profileOpens).toEqual([
			{ profileId: "research", sessionKey: "agent:research:main" },
		]);
		expect(harness.host.text).toContain("newphy");
	});

	test("/profile chat opens the canonical chat and uses the normal submission state machine", async () => {
		harness.store.setSubmissionMode("redirect");
		await harness.run("/profile chat research follow the primary sources");

		expect(harness.host.profileOpens).toEqual([
			{ profileId: "research", sessionKey: "agent:research:main" },
		]);
		expect(harness.host.deliveries).toEqual([
			{ text: "follow the primary sources", mode: "redirect" },
		]);
	});

	test("help and completion expose the profile commands", async () => {
		expect(harness.registry.has("profiles")).toBe(true);
		expect(harness.registry.has("profile")).toBe(true);
		expect(harness.registry.names()).toContain("profiles");

		await harness.run("/help profile");
		expect(harness.host.text).toContain("open, chat with, or manage");
		expect(harness.host.text).toContain("help|list|current|show|open|chat|create");

		await harness.run("/profile help");
		expect(harness.host.text).toContain("/profile delete <id> --confirm <id>");
		expect(harness.host.text).toContain("no workspace path option exists");
	});
});

describe("profile lifecycle", () => {
	test("create selects model and named node without accepting a workspace", async () => {
		harness.server.respondWith("profiles.create", { profile: research });

		await harness.run(
			'/profile create research --name "Research" --description "Evidence first" --model openai:gpt-5 --node newphy',
		);

		expect(harness.server.requestsFor("profiles.create")[0]?.params).toEqual({
			id: "research",
			name: "Research",
			description: "Evidence first",
			model: "openai:gpt-5",
			node: "newphy",
		});
		expect(harness.host.profileOpens[0]).toEqual({
			profileId: "research",
			sessionKey: "agent:research:main",
		});

		await harness.run("/profile create unsafe --workspace /tmp/elsewhere");
		expect(harness.server.requestsFor("profiles.create")).toHaveLength(1);
		expect(harness.host.last?.text).toContain('unknown profile option "--workspace"');
	});

	test("clone preserves the API-owned source and supports safe overrides", async () => {
		const copy = {
			...research,
			id: "research-copy",
			name: "Research Copy",
			canonicalSessionKey: "agent:research-copy:main",
		};
		harness.server.respondWith("profiles.clone", { profile: copy });

		await harness.run('/profile clone research research-copy --name "Research Copy" --node local');

		expect(harness.server.requestsFor("profiles.clone")[0]?.params).toEqual({
			sourceId: "research",
			id: "research-copy",
			name: "Research Copy",
			node: "local",
		});
		expect(harness.host.profileOpens[0]?.sessionKey).toBe("agent:research-copy:main");
	});

	test("rename never changes the canonical chat", async () => {
		harness.server.respondWith("profiles.rename", {
			profile: { ...research, name: "Research Prime" },
		});

		await harness.run("/profile rename research Research Prime");

		expect(harness.server.requestsFor("profiles.rename")[0]?.params).toEqual({
			id: "research",
			name: "Research Prime",
		});
		expect(harness.host.text).toContain("canonical chat remains agent:research:main");
	});

	test("export is explicit about force and private omissions", async () => {
		harness.server.respondWith("profiles.export", {
			export: {
				profileId: "research",
				path: "/tmp/research.json",
				fileCount: 4,
				redactionCount: 2,
			},
		});

		await harness.run("/profile export research /tmp/research.json --force");

		expect(harness.server.requestsFor("profiles.export")[0]?.params).toEqual({
			id: "research",
			path: "/tmp/research.json",
			force: true,
		});
		expect(harness.host.text).toContain("4 file(s) · 2 redaction(s)");
		expect(harness.host.text).toContain("sessions, memory, and credentials excluded");
	});

	test("delete requires an exact repeated id and forgets the route", async () => {
		harness.server.respondWith("profiles.delete", {
			deleted: {
				id: "research",
				canonicalSessionKey: "agent:research:main",
				homeMoved: true,
			},
		});

		await harness.run("/profile delete research");
		expect(harness.server.requestsFor("profiles.delete")).toHaveLength(0);
		expect(harness.host.text).toContain("--confirm research");

		await harness.run("/profile delete research --confirm wrong");
		expect(harness.server.requestsFor("profiles.delete")).toHaveLength(0);

		harness.store.setFocused("agent:research:main");
		await harness.run("/profile delete research --confirm research");
		expect(harness.server.requestsFor("profiles.delete")[0]?.params).toEqual({
			id: "research",
			confirm: "research",
		});
		expect(harness.host.forgottenProfiles).toEqual([
			{ profileId: "research", sessionKey: "agent:research:main" },
		]);
		expect(harness.host.createdSessions).toEqual([{ sessionKey: undefined, prompt: undefined }]);
		expect(harness.host.text).toContain("managed home moved to trash");
	});
});
