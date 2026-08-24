/**
 * The two-stage model picker, driven through the overlay it presents.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { ModelPicker } from "../../src/ui/components/model-picker.ts";
import type { PickerOverlay } from "../../src/ui/components/pickers.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { createHarness, type Harness } from "../helpers/command-harness.ts";
import { renderPlain } from "../helpers/memory-terminal.ts";

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
		expect(current().items.map((item) => item.value)).toEqual(["claude-sonnet-4", "claude-opus-4"]);
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
		expect(current().items.map((item) => item.value)).toEqual(["gpt-4o"]);
	});

	test("nothing to choose from is said, not shown", async () => {
		harness.server.respondWith("models.list", { models: [] });
		const picker = makePicker();
		await picker.open();
		expect(overlays).toHaveLength(0);
		expect(harness.host.text).toContain("no models");
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
			model: "claude-sonnet-4",
		});
		expect(harness.store.focused.model).toBe("claude-sonnet-4");
		expect(harness.host.statusRefreshes).toBeGreaterThan(0);
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

	test("hints describe the model", async () => {
		const picker = makePicker();
		await picker.open();
		current().handleInput(ENTER);
		const text = renderPlain(current().render(90));
		expect(text).toContain("200k ctx");
		expect(text).toContain("thinking");
	});
});
