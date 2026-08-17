import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { CommandHost } from "../../src/commands/index.ts";
import type { ThemePreference } from "../../src/ui/theme/appearance.ts";
import { getTheme, initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";

let harness: Harness;

/** What the multi-session and theme hooks were asked to do. */
interface HostSpy {
	switched: string[];
	created: Array<{ key?: string; prompt?: string }>;
	closed: string[];
	reset: string[];
	switcherOpens: number;
	preferences: ThemePreference[];
	themeChanges: number;
}

function withHooks(spy: HostSpy): Partial<CommandHost> {
	return {
		openSessionSwitcher: () => {
			spy.switcherOpens += 1;
		},
		switchSession: (key: string) => {
			spy.switched.push(key);
		},
		createSession: (key?: string, prompt?: string) => {
			spy.created.push({ key, prompt });
		},
		closeSession: (key: string) => {
			spy.closed.push(key);
		},
		resetSession: (key: string) => {
			spy.reset.push(key);
		},
		setThemePreference: (preference: ThemePreference) => {
			spy.preferences.push(preference);
			return preference === "auto" ? "dark" : preference;
		},
		themeChanged: () => {
			spy.themeChanges += 1;
		},
	};
}

let spy: HostSpy;

/** Run a line against a host that has the multi-session seams wired. */
function runWired(line: string): Promise<boolean> {
	const context = harness.context();
	return harness.registry.dispatch(line, {
		...context,
		ui: Object.assign(Object.create(Object.getPrototypeOf(harness.host)), harness.host, {
			...withHooks(spy),
		}) as CommandHost,
	});
}

beforeEach(async () => {
	initTheme({ colorLevel: 3 });
	harness = await createHarness({ sessionKey: "tui-session" });
	spy = {
		switched: [],
		created: [],
		closed: [],
		reset: [],
		switcherOpens: 0,
		preferences: [],
		themeChanges: 0,
	};
});

afterEach(() => {
	harness.stop();
	resetTheme();
	invalidateThemeAdapters();
});

describe("session commands with the switcher mounted", () => {
	test("/sessions opens the switcher instead of a plain picker", async () => {
		await runWired("/sessions");
		expect(spy.switcherOpens).toBe(1);
		expect(harness.host.pickers).toHaveLength(0);
	});

	test("/session new passes the key and the rest of the line as a first prompt", async () => {
		await runWired("/session new review-branch look at the diff");
		expect(spy.created).toEqual([{ key: "review-branch", prompt: "look at the diff" }]);
	});

	test("/session new with no arguments lets the host mint the key", async () => {
		await runWired("/session new");
		expect(spy.created).toEqual([{ key: undefined, prompt: undefined }]);
	});

	test("/session reset clears both copies", async () => {
		harness.server.respondWith("sessions.reset", { ok: true });
		await runWired("/session reset");
		expect(harness.server.requestsFor("sessions.reset")[0].params).toEqual({
			sessionKey: "tui-session",
		});
		expect(spy.reset).toEqual(["tui-session"]);
	});

	test("/session delete hands the confirmation to the host", async () => {
		harness.server.respondWith("sessions.delete", { ok: true });
		await runWired("/session delete tui-other");
		// The host asks in an overlay; the command must not delete behind it.
		expect(spy.closed).toEqual(["tui-other"]);
		expect(harness.server.requestsFor("sessions.delete")).toHaveLength(0);
	});

	test("/session delete with no key means the focused one", async () => {
		await runWired("/session delete");
		expect(spy.closed).toEqual(["tui-session"]);
	});

	test("/resume for another session switches to it rather than mixing transcripts", async () => {
		await runWired("/resume other-session");
		expect(spy.switched).toEqual(["other-session"]);
		expect(harness.server.requestsFor("chat.history")).toHaveLength(0);
	});

	test("/resume for the focused session still replays into it", async () => {
		harness.server.respondWith("chat.history", {
			messages: [{ id: "m1", role: "user", content: "hello", timestampMs: 1 }],
		});
		await runWired("/resume tui-session");
		expect(spy.switched).toEqual([]);
		expect(harness.server.requestsFor("chat.history")).toHaveLength(1);
	});
});

describe("/theme", () => {
	let home: string;
	let previousHome: string | undefined;

	beforeEach(() => {
		// `/theme` persists the choice; keep that off the real config file.
		previousHome = process.env.HOME;
		home = mkdtempSync(join(tmpdir(), "lemon-tui-theme-"));
		process.env.HOME = home;
	});

	afterEach(() => {
		if (previousHome === undefined) delete process.env.HOME;
		else process.env.HOME = previousHome;
		rmSync(home, { recursive: true, force: true });
	});

	test("installs a preference through the host and persists it", async () => {
		await runWired("/theme light");
		expect(spy.preferences).toEqual(["light"]);
		expect(spy.themeChanges).toBe(1);
		expect(readFileSync(join(home, ".lemon", "config.toml"), "utf-8")).toContain('theme = "light"');
	});

	test("auto reports the appearance it resolved to", async () => {
		await runWired("/theme auto");
		expect(spy.preferences).toEqual(["auto"]);
		expect(harness.host.text).toContain("auto (dark)");
	});

	test("without a host hook it still installs the palette itself", async () => {
		await harness.run("/theme light");
		expect(getTheme().appearance).toBe("light");
	});

	test("rejects a name it cannot install", async () => {
		await runWired("/theme neon");
		expect(spy.preferences).toEqual([]);
		expect(harness.host.last?.level).toBe("error");
		expect(harness.host.text).toContain("dark, light, auto");
	});

	test("with no argument it says what is installed and where that came from", async () => {
		await runWired("/theme");
		expect(harness.host.text).toContain("lemon-dark");
		expect(harness.host.text).toContain("auto");
	});
});
