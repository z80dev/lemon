import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import type { SessionRow } from "../../src/commands/session.ts";
import { FakeControlPlane } from "../../src/dev/fake-server.ts";
import { ControlPlaneClient } from "../../src/protocol/client.ts";
import { ControlPlaneMethods } from "../../src/protocol/methods.ts";
import { cwdSessionTag } from "../../src/session-key.ts";
import { AppStore } from "../../src/store/app-store.ts";
import type { PickerOverlay } from "../../src/ui/components/pickers.ts";
import {
	describeSessionRow,
	relativeAge,
	SessionSwitcher,
} from "../../src/ui/components/session-switcher.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { renderPlain } from "../helpers/memory-terminal.ts";
import { waitFor } from "../helpers/wait.ts";

const teardown: Array<() => void> = [];

beforeEach(() => {
	initTheme({ colorLevel: 0 });
});

afterEach(() => {
	while (teardown.length > 0) teardown.pop()?.();
	resetTheme();
	invalidateThemeAdapters();
});

const row = (overrides: Partial<SessionRow> = {}): SessionRow => ({
	key: "tui-a",
	active: false,
	local: true,
	unread: 0,
	pinned: false,
	archived: false,
	...overrides,
});

/** A TSP terminal that draws the `picker` kind. */
const NATIVE = {
	cols: 80,
	dark: true,
	reduceMotion: true,
	supports: () => true,
	feature: () => false,
};

const action = (act: string) => ({ type: "action" as const, key: "", act, mods: [] });

interface SwitcherHarness {
	switcher: SessionSwitcher;
	store: AppStore;
	server: FakeControlPlane;
	overlay(): PickerOverlay;
	rendered(): string;
	switched: string[];
	created: Array<{ key: string | undefined; prompt: string | undefined }>;
	closed: string[];
	notices: string[];
	presented: PickerOverlay[];
}

async function bootSwitcher(
	options: {
		sessionKey?: string;
		active?: Array<Record<string, unknown>>;
		stored?: Array<Record<string, unknown>>;
		now?: number;
		onSwitch?: (key: string) => void;
	} = {},
): Promise<SwitcherHarness> {
	const server = await FakeControlPlane.start();
	teardown.push(() => server.stop());
	server.respondWith("sessions.active.list", { sessions: options.active ?? [] });
	server.onMethod("sessions.list", (params: { query?: string }) => ({
		sessions: (options.stored ?? []).filter(
			(row) => !params.query || String(row.sessionKey).includes(params.query),
		),
	}));

	const client = new ControlPlaneClient({
		url: server.url,
		socketOptions: { minBackoffMs: 10, maxBackoffMs: 20, jitter: 0 },
	});
	teardown.push(() => client.close());
	await client.connect();

	const store = new AppStore(options.sessionKey ?? "tui-a");
	const presented: PickerOverlay[] = [];
	const switched: string[] = [];
	const created: Array<{ key: string | undefined; prompt: string | undefined }> = [];
	const closed: string[] = [];
	const notices: string[] = [];

	const switcher = new SessionSwitcher({
		store,
		methods: new ControlPlaneMethods(client),
		present: (overlay) => {
			presented.push(overlay);
			return () => {};
		},
		repaint: () => {},
		switchSession: (key) => {
			switched.push(key);
			options.onSwitch?.(key);
		},
		createSession: (key, prompt) => {
			created.push({ key, prompt });
		},
		closeSession: (key) => {
			closed.push(key);
		},
		notice: (text) => notices.push(text),
		cwd: "/repo",
		now: () => options.now ?? Date.now(),
	});
	teardown.push(() => switcher.close());

	return {
		switcher,
		store,
		server,
		presented,
		switched,
		created,
		closed,
		notices,
		overlay: () => {
			const overlay = presented[presented.length - 1];
			if (!overlay) throw new Error("no overlay was presented");
			return overlay;
		},
		rendered: () => renderPlain(presented[presented.length - 1]?.render(80) ?? []),
	};
}

describe("describeSessionRow", () => {
	test("names the focused session and shows what it is doing", () => {
		const item = describeSessionRow(
			row({ key: "tui-a", model: "claude-sonnet-4", active: true }),
			"tui-a",
			10_000,
		);
		expect(item.value).toBe("tui-a");
		expect(item.description).toContain("current");
		expect(item.description).toContain("claude-sonnet-4");
		expect(item.description).toContain("busy");
	});

	test("shows unread counts and an age for sessions off screen", () => {
		const item = describeSessionRow(
			row({ key: "tui-b", unread: 3, updatedAtMs: 1_000_000 }),
			"tui-a",
			1_000_000 + 125_000,
		);
		expect(item.description).not.toContain("current");
		expect(item.description).toContain("idle");
		expect(item.description).toContain("3 unread");
		expect(item.description).toContain("2m ago");
	});

	test("marks sessions the client has no transcript for", () => {
		const item = describeSessionRow(row({ key: "tui-c", local: false }), "tui-a", 0);
		expect(item.description).toContain("not loaded");
	});
});

describe("relativeAge", () => {
	test("uses the coarsest unit that is still true", () => {
		const now = 10_000_000_000;
		expect(relativeAge(now - 5_000, now)).toBe("5s ago");
		expect(relativeAge(now - 90_000, now)).toBe("2m ago");
		expect(relativeAge(now - 7_200_000, now)).toBe("2h ago");
		expect(relativeAge(now - 172_800_000, now)).toBe("2d ago");
	});

	test("has nothing to say about a session with no timestamp", () => {
		expect(relativeAge(undefined, 1000)).toBeUndefined();
		expect(relativeAge(0, 1000)).toBeUndefined();
	});
});

describe("SessionSwitcher", () => {
	test("merges live, stored and local sessions, live ones first", async () => {
		const harness = await bootSwitcher({
			sessionKey: "tui-local",
			active: [{ sessionKey: "tui-live", updatedAtMs: 10 }],
			stored: [{ sessionKey: "tui-stored", updatedAtMs: 5 }],
		});

		await harness.switcher.open();

		expect(harness.switcher.rows.map((entry) => entry.key)).toEqual([
			"tui-live",
			"tui-stored",
			"tui-local",
		]);
		const text = harness.rendered();
		expect(text).toContain("tui-live");
		expect(text).toContain("tui-stored");
		expect(text).toContain("tui-local");
	});

	test("a session known both live and locally appears once", async () => {
		const harness = await bootSwitcher({
			sessionKey: "tui-a",
			active: [{ sessionKey: "tui-a" }],
			stored: [{ sessionKey: "tui-a" }],
		});

		await harness.switcher.open();

		expect(harness.switcher.rows).toHaveLength(1);
	});

	test("typing filters the list", async () => {
		const harness = await bootSwitcher({
			sessionKey: "tui-alpha",
			stored: [{ sessionKey: "review-branch" }, { sessionKey: "tui-beta" }],
		});
		await harness.switcher.open();

		harness.overlay().handleInput("review");
		// Exercise the actual debounce and WebSocket response, not a guessed delay.
		await waitFor(() => harness.overlay().items.length === 1, { what: "server session search" });
		expect(harness.server.requestsFor("sessions.list").at(-1)?.params).toMatchObject({
			query: "review",
		});

		expect(harness.overlay().items.map((item) => item.value)).toEqual(["review-branch"]);
		expect(harness.rendered()).not.toContain("tui-beta");
	});

	test("enter switches to the selected session", async () => {
		const harness = await bootSwitcher({
			sessionKey: "tui-a",
			stored: [{ sessionKey: "tui-b", updatedAtMs: 99 }],
		});
		await harness.switcher.open();

		harness.overlay().handleInput("tui-b");
		await waitFor(() => harness.overlay().selected?.value === "tui-b", {
			what: "search selection",
		});
		harness.overlay().handleInput("\r");

		expect(harness.switched).toEqual(["tui-b"]);
		expect(harness.switcher.isOpen).toBe(false);
	});

	test("a session from another directory is marked and refused without leaving a store", async () => {
		const foreign = `agent:default:tui:local:dm:${cwdSessionTag("/elsewhere")}-x`;
		const harness = await bootSwitcher({
			sessionKey: "tui-a",
			stored: [{ sessionKey: foreign, updatedAtMs: 99 }],
		});
		await harness.switcher.open();
		harness.overlay().handleInput(foreign.slice(-20));
		await waitFor(() => harness.overlay().selected?.value === foreign, { what: "the row" });
		expect(harness.rendered()).toContain("other directory");

		harness.overlay().handleInput("\r");
		await waitFor(() => harness.notices.length > 0, { what: "the refusal notice" });

		expect(harness.notices[0]).toContain("another directory");
		expect(harness.switched).toEqual([]);
		expect(harness.store.focusedKey).toBe("tui-a");
		expect(harness.store.sessions.has(foreign)).toBe(false);
	});

	test("a failing switch is reported, never thrown out of the switcher", async () => {
		const harness = await bootSwitcher({
			sessionKey: "tui-a",
			stored: [{ sessionKey: "tui-b", updatedAtMs: 99 }],
			onSwitch: () => {
				throw new Error("switch exploded");
			},
		});
		await harness.switcher.open();
		harness.overlay().handleInput("tui-b");
		await waitFor(() => harness.overlay().selected?.value === "tui-b", { what: "the row" });
		harness.overlay().handleInput("\r");
		await waitFor(() => harness.notices.length > 0, { what: "the failure notice" });

		expect(harness.notices[0]).toContain("could not switch session");
		expect(harness.store.sessions.has("tui-b")).toBe(false);
	});

	test("ctrl+n opens an inline prompt, and enter creates the session with it", async () => {
		const harness = await bootSwitcher();
		await harness.switcher.open();

		harness.overlay().handleInput("\x0e");
		expect(harness.switcher.promptMode).toBe(true);
		for (const char of "review the diff") harness.overlay().handleInput(char);
		expect(harness.rendered()).toContain("review the diff");
		expect(harness.rendered()).toContain("enter creates the session");

		harness.overlay().handleInput("\r");

		expect(harness.created).toEqual([{ key: undefined, prompt: "review the diff" }]);
		expect(harness.switched).toEqual([]);
	});

	test("prompt-mode text is not treated as a filter", async () => {
		const harness = await bootSwitcher({
			sessionKey: "tui-a",
			stored: [{ sessionKey: "tui-b" }],
		});
		await harness.switcher.open();

		harness.overlay().handleInput("\x0e");
		for (const char of "zzz") harness.overlay().handleInput(char);

		expect(harness.overlay().filter).toBe("");
		expect(harness.overlay().items).toHaveLength(2);
	});

	test("escape leaves prompt mode without closing the switcher", async () => {
		const harness = await bootSwitcher();
		await harness.switcher.open();

		harness.overlay().handleInput("\x0e");
		harness.overlay().handleInput("\x1b");

		expect(harness.switcher.promptMode).toBe(false);
		expect(harness.switcher.isOpen).toBe(true);
		expect(harness.created).toEqual([]);
	});

	test("ctrl+w asks the host to close the selected session", async () => {
		const harness = await bootSwitcher({
			sessionKey: "tui-a",
			stored: [{ sessionKey: "tui-b", updatedAtMs: 99 }],
		});
		await harness.switcher.open();

		harness.overlay().handleInput("tui-b");
		await waitFor(() => harness.overlay().selected?.value === "tui-b", {
			what: "search selection",
		});
		harness.overlay().handleInput("\x17");

		expect(harness.closed).toEqual(["tui-b"]);
		// The confirmation replaces this overlay rather than stacking on it.
		expect(harness.switcher.isOpen).toBe(false);
	});

	test("a click selects and confirms the row under the pointer", async () => {
		const harness = await bootSwitcher({
			sessionKey: "tui-a",
			stored: [{ sessionKey: "tui-b", updatedAtMs: 99 }, { sessionKey: "tui-c" }],
		});
		await harness.switcher.open();
		const overlay = harness.overlay();
		overlay.render(80);
		const rows = overlay.items.map((item) => item.value);

		// Row 0 is the box's top border, 1 the title, 2 the filter line; the list
		// body starts at 3, so the second item is on screen row 4 (1-based in the
		// SGR report).
		overlay.handleInput("\x1b[<0;10;5M");

		expect(harness.switched).toEqual([rows[1]]);
	});

	test("a click cannot confirm a row out from under the inline prompt", async () => {
		const harness = await bootSwitcher({
			sessionKey: "tui-a",
			stored: [{ sessionKey: "tui-b", updatedAtMs: 99 }],
		});
		await harness.switcher.open();
		const overlay = harness.overlay();
		overlay.render(80);

		overlay.handleInput("\x0e");
		for (const char of "half typed") overlay.handleInput(char);
		overlay.handleInput("\x1b[<0;10;5M");

		expect(harness.switched).toEqual([]);
		expect(harness.switcher.promptText).toBe("half typed");
	});

	test("the wheel scrolls the list instead of the transcript", async () => {
		const harness = await bootSwitcher({
			sessionKey: "tui-a",
			stored: Array.from({ length: 40 }, (_, index) => ({ sessionKey: `tui-${index}` })),
		});
		await harness.switcher.open();
		const overlay = harness.overlay();
		const before = renderPlain(overlay.render(80));

		for (let tick = 0; tick < 8; tick++) overlay.handleInput("\x1b[<65;10;6M");

		expect(renderPlain(overlay.render(80))).not.toBe(before);
		expect(harness.switched).toEqual([]);
	});

	test("on a native sheet, a row double-click switches and the buttons run the keys", async () => {
		const harness = await bootSwitcher({
			sessionKey: "tui-a",
			stored: [{ sessionKey: "tui-b", updatedAtMs: 99 }],
		});
		await harness.switcher.open();
		const overlay = harness.overlay();
		const sheet = overlay.describe(NATIVE);
		expect(sheet?.k).toBe("picker");
		expect(sheet?.p).toMatchObject({ current: ["tui-a"], order: ["tui-b", "tui-a"] });

		overlay.handleNativeEvent(action("new"));
		expect(harness.switcher.promptMode).toBe(true);
		// The prompt owns the pointer as it owns the keyboard.
		overlay.handleNativeEvent({ type: "activate", key: "", item: "tui-b" });
		expect(harness.switched).toEqual([]);
		overlay.handleNativeEvent(action("close"));
		expect(harness.switcher.promptMode).toBe(false);

		overlay.handleNativeEvent({ type: "activate", key: "", item: "tui-b" });
		await waitFor(() => harness.switched.length > 0, { what: "the switch" });
		expect(harness.switched).toEqual(["tui-b"]);
	});

	test("the native Close session button asks the host to close the selected session", async () => {
		const harness = await bootSwitcher({ sessionKey: "tui-a" });
		await harness.switcher.open();
		harness.overlay().handleNativeEvent(action("close-session"));
		expect(harness.closed).toEqual(["tui-a"]);
	});
});

test("server content matches are not removed by a second local metadata filter", async () => {
	const harness = await bootSwitcher();
	await harness.switcher.open();
	harness.server.respondWith("sessions.list", {
		sessions: [{ sessionKey: "older-session", title: "Parser review" }],
	});
	harness.overlay().handleInput("needle-in-message-history");
	expect(harness.overlay().items).toHaveLength(0);
	await waitFor(() => harness.overlay().items.length === 1, { what: "content search result" });
	expect(harness.overlay().items[0].value).toBe("older-session");
	harness.overlay().handleInput("\r");
	expect(harness.store.session("older-session").title).toBe("Parser review");
});

test("failed server search cannot leave an old row selectable under a new query", async () => {
	const harness = await bootSwitcher({ stored: [{ sessionKey: "old-session" }] });
	await harness.switcher.open();
	harness.server.failWith("sessions.list", "UNAVAILABLE", "search unavailable");
	harness.overlay().handleInput("new");
	await waitFor(() => harness.rendered().includes("search failed"), { what: "search failure" });
	harness.overlay().handleInput("\r");
	expect(harness.switched).toEqual([]);
	expect(harness.overlay().items).toHaveLength(0);
});
