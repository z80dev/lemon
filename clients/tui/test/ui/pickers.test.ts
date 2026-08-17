import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import {
	filterItems,
	isPrintable,
	type PickerItem,
	PickerOverlay,
} from "../../src/ui/components/pickers.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { renderPlain } from "../helpers/memory-terminal.ts";

const ITEMS: PickerItem[] = [
	{ value: "claude-sonnet-4", label: "claude-sonnet-4", description: "anthropic · 200k ctx" },
	{ value: "claude-opus-4", label: "claude-opus-4", description: "anthropic · 200k ctx" },
	{ value: "gpt-4o", label: "gpt-4o", description: "openai · 128k ctx" },
];

const ESC = "\x1b";
const ENTER = "\r";
const BACKSPACE = "\x7f";
const DOWN = "\x1b[B";

beforeEach(() => {
	initTheme({ colorLevel: 3 });
});

afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

describe("filterItems", () => {
	test("an empty query keeps the caller's order", () => {
		expect(filterItems(ITEMS, "").map((item) => item.value)).toEqual([
			"claude-sonnet-4",
			"claude-opus-4",
			"gpt-4o",
		]);
	});

	test("matches on the label", () => {
		expect(filterItems(ITEMS, "opus").map((item) => item.value)).toEqual(["claude-opus-4"]);
	});

	test("matches on the description", () => {
		expect(filterItems(ITEMS, "openai").map((item) => item.value)).toEqual(["gpt-4o"]);
	});

	test("ranks better matches first", () => {
		expect(filterItems(ITEMS, "op")[0].value).toBe("claude-opus-4");
	});

	test("a query nothing matches yields nothing", () => {
		expect(filterItems(ITEMS, "zzzz")).toEqual([]);
	});

	test("whitespace-only queries are treated as empty", () => {
		expect(filterItems(ITEMS, "   ")).toHaveLength(3);
	});
});

describe("isPrintable", () => {
	test("accepts text and rejects control and escape sequences", () => {
		expect(isPrintable("a")).toBe(true);
		expect(isPrintable("日")).toBe(true);
		expect(isPrintable(ESC)).toBe(false);
		expect(isPrintable(DOWN)).toBe(false);
		expect(isPrintable("\x03")).toBe(false);
		expect(isPrintable(BACKSPACE)).toBe(false);
		expect(isPrintable("")).toBe(false);
	});
});

describe("PickerOverlay", () => {
	type Options = ConstructorParameters<typeof PickerOverlay>[0];

	function makePicker(overrides: Partial<Options> = {}) {
		const selected: PickerItem[] = [];
		let cancelled = 0;
		const overlay = new PickerOverlay({
			title: "models",
			items: [...ITEMS],
			onSelect: (item: PickerItem) => {
				selected.push(item);
			},
			onCancel: () => {
				cancelled += 1;
			},
			...overrides,
		});
		return {
			overlay,
			selected,
			get cancelled() {
				return cancelled;
			},
		};
	}

	test("typing filters and backspace unfilters", () => {
		const { overlay } = makePicker();
		overlay.handleInput("o");
		overlay.handleInput("p");
		expect(overlay.filter).toBe("op");
		// Ranked, not merely filtered: "anthropic" and "openai" also contain "op",
		// but the label match wins.
		expect(overlay.items[0].value).toBe("claude-opus-4");
		overlay.handleInput(BACKSPACE);
		overlay.handleInput(BACKSPACE);
		expect(overlay.items).toHaveLength(3);
	});

	test("Enter selects the highlighted item", () => {
		const picker = makePicker();
		picker.overlay.handleInput(DOWN);
		picker.overlay.handleInput(ENTER);
		expect(picker.selected.map((item) => item.value)).toEqual(["claude-opus-4"]);
	});

	test("Esc cancels", () => {
		const picker = makePicker();
		picker.overlay.handleInput(ESC);
		expect(picker.cancelled).toBe(1);
		expect(picker.selected).toHaveLength(0);
	});

	test("a host key gets first refusal", () => {
		const seen: string[] = [];
		const picker = makePicker({
			onKey: (data: string) => {
				seen.push(data);
				return data === "\x07";
			},
		});
		picker.overlay.handleInput("\x07");
		picker.overlay.handleInput(ESC);
		expect(seen).toEqual(["\x07", ESC]);
		expect(picker.cancelled).toBe(1);
	});

	test("selecting nothing when the filter matches nothing", () => {
		const picker = makePicker();
		picker.overlay.handleInput("z");
		picker.overlay.handleInput(ENTER);
		expect(picker.selected).toHaveLength(0);
	});

	test("every row fits the overlay width", () => {
		const { overlay } = makePicker();
		for (const width of [40, 60, 80, 120]) {
			for (const line of overlay.render(width)) {
				expect(visibleWidth(line)).toBeLessThanOrEqual(width);
			}
		}
	});

	test("renders the title, the items and the counts", () => {
		const { overlay } = makePicker();
		const text = renderPlain(overlay.render(60));
		expect(text).toContain("models");
		expect(text).toContain("claude-sonnet-4");
		expect(text).toContain("3/3");
	});

	test("the same array comes back while nothing changed", () => {
		const { overlay } = makePicker();
		const first = overlay.render(60);
		expect(overlay.render(60)).toBe(first);
		overlay.handleInput("o");
		expect(overlay.render(60)).not.toBe(first);
	});

	test("a second stage replaces the items and clears the filter", () => {
		const { overlay } = makePicker();
		overlay.handleInput("o");
		overlay.setItems([{ value: "anthropic", label: "anthropic" }]);
		expect(overlay.filter).toBe("");
		expect(overlay.items).toHaveLength(1);
	});
});
