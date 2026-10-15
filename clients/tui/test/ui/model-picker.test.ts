/**
 * The two-stage model picker, driven through the overlay it presents.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setNativeRendering } from "@oh-my-pi/pi-tui/native/state";
import { ModelPicker } from "../../src/ui/components/model-picker.ts";
import type { PickerOverlay } from "../../src/ui/components/pickers.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";
import { renderPlain } from "../helpers/memory-terminal.ts";
import { waitFor } from "../helpers/wait.ts";

const ESC = "\x1b";
const ENTER = "\r";
const CTRL_G = "\x07";
const BACKSPACE = "\x7f";

let harness: Harness;
let overlays: PickerOverlay[];
let closed: number;

const MODELS = [
	{ id: "claude-sonnet-4", provider: "anthropic", contextWindow: 200_000, supportsThinking: true },
	{ id: "claude-opus-4", provider: "anthropic", contextWindow: 200_000 },
	{ id: "gpt-4o", provider: "openai", contextWindow: 128_000, supportsVision: true },
];

function makePicker(): ModelPicker {
	return new ModelPicker({
		store: harness.store,
		methods: harness.methods,
		session: () => harness.store.focused,
		notice: (text, level) => harness.host.notice(text, level),
		refreshStatus: () => harness.host.refreshStatus(),
		present: (overlay) => {
			overlays.push(overlay);
			return () => {
				closed += 1;
			};
		},
		repaint: () => {},
	});
}

function current(): PickerOverlay {
	return overlays[overlays.length - 1];
}

beforeEach(async () => {
	initTheme({ colorLevel: 3 });
	harness = await createHarness({ sessionKey: "tui-session" });
	harness.server.respondWith("models.list", { models: MODELS });
	harness.server.respondWith("sessions.patch", { success: true });
	overlays = [];
	closed = 0;
});

afterEach(() => {
	harness.stop();
	resetTheme();
	invalidateThemeAdapters();
});

describe("stages", () => {
	test("opens on providers with model counts", async () => {
		const picker = makePicker();
		await picker.open();
		expect(picker.stage).toBe("provider");
		expect(current().items.map((item) => item.value)).toEqual(["anthropic", "openai"]);
		expect(current().items[0].description).toBe("2 model(s)");
	});

	test("selecting a provider opens its models", async () => {
		const picker = makePicker();
		await picker.open();
		current().handleInput(ENTER);
		expect(picker.stage).toBe("model");
		expect(current().items.map((item) => item.value)).toEqual([
			"anthropic:claude-sonnet-4",
			"anthropic:claude-opus-4",
		]);
		expect(renderPlain(current().render(70))).toContain("anthropic");
	});

	test("Esc in the model stage goes back to providers", async () => {
		const picker = makePicker();
		await picker.open();
		current().handleInput(ENTER);
		current().handleInput(ESC);
		expect(picker.stage).toBe("provider");
	});

	test("backspace on an empty filter also steps back", async () => {
		const picker = makePicker();
		await picker.open();
		current().handleInput(ENTER);
		current().handleInput(BACKSPACE);
		expect(picker.stage).toBe("provider");
	});

	test("Esc in the provider stage closes the picker", async () => {
		const picker = makePicker();
		await picker.open();
		const before = closed;
		current().handleInput(ESC);
		expect(closed).toBeGreaterThan(before);
	});

	test("a single provider skips the first stage", async () => {
		harness.server.respondWith("models.list", { models: [MODELS[2]] });
		const picker = makePicker();
		await picker.open();
		expect(picker.stage).toBe("model");
		expect(current().items.map((item) => item.value)).toEqual(["openai:gpt-4o"]);
	});

	test("nothing to choose from is said, not shown", async () => {
		harness.server.respondWith("models.list", { models: [] });
		const picker = makePicker();
		await picker.open();
		expect(overlays).toHaveLength(0);
		expect(harness.host.text).toContain("no models");
	});

	test("cycling uses the cached model order and wraps without opening a picker", async () => {
		harness.store.focused.model = "claude-sonnet-4";
		const picker = makePicker();
		await picker.cycle();
		expect(harness.store.focused.model).toBe("anthropic:claude-opus-4");
		await picker.cycle();
		expect(harness.store.focused.model).toBe("openai:gpt-4o");
		await picker.cycle();
		expect(harness.store.focused.model).toBe("anthropic:claude-sonnet-4");
		expect(harness.server.requestsFor("models.list")).toHaveLength(1);
		expect(harness.server.requestsFor("sessions.patch")).toHaveLength(3);
		expect(overlays).toHaveLength(0);
	});

	test("cycling with no current model selects the first model", async () => {
		await makePicker().cycle();
		expect(harness.store.focused.model).toBe("anthropic:claude-sonnet-4");
	});

	test("cycling an empty list reports a notice without mutating the session", async () => {
		harness.server.respondWith("models.list", { models: [] });
		await makePicker().cycle();
		expect(harness.host.text).toContain("no models");
		expect(harness.server.requestsFor("sessions.patch")).toHaveLength(0);
	});

	test("failed cycling keeps the prior model and reports the failure", async () => {
		harness.store.focused.model = "anthropic:claude-sonnet-4";
		harness.server.failWith("sessions.patch", "FORBIDDEN", "not allowed");
		await makePicker().cycle();
		expect(harness.store.focused.model).toBe("anthropic:claude-sonnet-4");
		expect(harness.host.text).toContain("could not set model");
	});
});

describe("applying", () => {
	test("Enter on a model patches the session", async () => {
		const picker = makePicker();
		await picker.open();
		current().handleInput(ENTER);
		current().handleInput(ENTER);
		await Bun.sleep(20);
		expect(harness.server.requestsFor("sessions.patch")[0].params).toEqual({
			sessionKey: "tui-session",
			model: "anthropic:claude-sonnet-4",
		});
		expect(harness.store.focused.model).toBe("anthropic:claude-sonnet-4");
		expect(harness.host.statusRefreshes).toBeGreaterThan(0);
	});

	test("Make default writes [defaults] and keeps the rest of config.toml", async () => {
		const previousHome = process.env.HOME;
		const home = mkdtempSync(join(tmpdir(), "lemon-tui-default-"));
		process.env.HOME = home;
		try {
			mkdirSync(join(home, ".lemon"));
			const original = [
				"# setup wrote this",
				"[defaults]",
				'provider = "openai-codex"',
				'model = "openai-codex:gpt-5"',
				"",
				'[providers."openai-codex"]',
				'oauth_secret = "llm_openai_codex_api_key"',
				"",
				"[gateway]",
				"max_concurrent_runs = 2",
				"",
			].join("\n");
			writeFileSync(join(home, ".lemon", "config.toml"), original);

			const picker = makePicker();
			await picker.open();
			current().handleInput("openai");
			current().handleInput(ENTER);
			current().handleInput(CTRL_G);
			current().handleInput(ENTER);
			await waitFor(() => harness.host.text.includes("default model: openai:gpt-4o"));

			const written = readFileSync(join(home, ".lemon", "config.toml"), "utf-8");
			expect(written).toBe(
				original
					.replace('provider = "openai-codex"', 'provider = "openai"')
					.replace('model = "openai-codex:gpt-5"', 'model = "openai:gpt-4o"'),
			);
			expect(written).not.toContain("[agent]");
		} finally {
			if (previousHome === undefined) delete process.env.HOME;
			else process.env.HOME = previousHome;
			rmSync(home, { recursive: true, force: true });
		}
	});

	test("Ctrl+G toggles the global persist hint", async () => {
		const picker = makePicker();
		await picker.open();
		current().handleInput(ENTER);
		expect(picker.persistGlobally).toBe(false);
		current().handleInput(CTRL_G);
		expect(picker.persistGlobally).toBe(true);
		expect(renderPlain(current().render(80))).toContain("global+session");
	});

	test("the models cache is reused within its TTL", async () => {
		const picker = makePicker();
		await picker.open();
		current().handleInput(ESC);
		await makePicker().open();
		expect(harness.server.requestsFor("models.list")).toHaveLength(1);
	});

	test("the current model is marked in the list", async () => {
		harness.store.focused.model = "gpt-4o";
		const picker = makePicker();
		await picker.open();
		// openai is the second provider.
		current().handleInput("openai");
		current().handleInput(ENTER);
		expect(current().items[0].label).toContain("(current)");
	});

	test("provider search does not contaminate the model search or back navigation", async () => {
		const picker = makePicker();
		await picker.open();
		current().handleInput("anthropic");
		current().handleInput(ENTER);
		expect(current().filter).toBe("");
		current().handleInput("sonnet");
		expect(renderPlain(current().render(80))).toContain("claude-sonnet-4");
		current().handleInput(ESC);
		expect(current().filter).toBe("");
	});

	test("switching models replaces stale context and provider metadata", async () => {
		harness.store.focused.setModel(
			{ model: "openai:gpt-4o", provider: "openai", contextWindow: 128_000 },
			"run",
		);
		const picker = makePicker();
		await picker.open();
		current().handleInput(ENTER);
		current().handleInput(ENTER);
		await waitFor(() => harness.store.focused.modelSource === "local", { what: "model patch" });
		expect(harness.store.focused.contextWindow).toBe(200_000);
		expect(harness.store.focused.provider).toBe("anthropic");
	});

	test("hints describe the model", async () => {
		const picker = makePicker();
		await picker.open();
		current().handleInput(ENTER);
		const text = renderPlain(current().render(90));
		expect(text).toContain("200k ctx");
		expect(text).toContain("thinking");
	});
});

test("an exact model ID ranks before a longer sibling even when marked current", async () => {
	harness.server.respondWith("models.list", {
		models: [
			{ id: "gpt-5.5-pro", provider: "openai-codex" },
			{ id: "gpt-5.5", provider: "openai-codex" },
		],
	});
	harness.store.focused.model = "openai-codex:gpt-5.5";
	const picker = makePicker();
	await picker.open();
	current().handleInput("gpt-5.5");
	expect(current().selected?.value).toBe("openai-codex:gpt-5.5");
});

test("a native surface gets one provider-grouped stage with the current model marked", async () => {
	harness.store.focused.model = "gpt-4o";
	setNativeRendering(true);
	try {
		const picker = makePicker();
		await picker.open();
		expect(picker.stage).toBe("model");
		const sheet = current().describe({
			cols: 80,
			dark: true,
			reduceMotion: true,
			supports: () => true,
			feature: () => false,
		});
		expect(sheet?.p).toMatchObject({
			current: ["openai:gpt-4o"],
			order: [
				{ group: "anthropic:0", label: "anthropic", count: 2 },
				"anthropic:claude-sonnet-4",
				"anthropic:claude-opus-4",
				{ group: "openai:2", label: "openai", count: 1 },
				"openai:gpt-4o",
			],
		});
		// Esc closes rather than stepping back to a provider stage that is not shown.
		const before = closed;
		current().handleInput(ESC);
		expect(closed).toBeGreaterThan(before);
	} finally {
		setNativeRendering(false);
	}
});

test("the native Make default button toggles persistence like Ctrl+G", async () => {
	const picker = makePicker();
	await picker.open();
	current().handleInput(ENTER);
	current().handleNativeEvent({ type: "action", key: "", act: "global", mods: [] });
	expect(picker.persistGlobally).toBe(true);
});
