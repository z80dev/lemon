import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import type { QueueItem } from "../../src/store/queue-store.ts";
import { QUEUE_WINDOW, QueuePanelComponent } from "../../src/ui/components/queue-panel.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { renderPlain } from "../helpers/memory-terminal.ts";

beforeEach(() => {
	initTheme({ colorLevel: 3 });
});

afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

function items(...texts: string[]): QueueItem[] {
	return texts.map((text, index) => ({
		id: `q-${index}`,
		text,
		state: "queued-local",
		at: 0,
	}));
}

function build(list: QueueItem[] = items("first", "second")) {
	const edited: QueueItem[] = [];
	const deleted: QueueItem[] = [];
	let blurred = 0;
	const panel = new QueuePanelComponent({
		onEdit: (item) => edited.push(item),
		onDelete: (item) => deleted.push(item),
		onBlur: () => {
			blurred += 1;
		},
	});
	panel.update(list);
	return { panel, edited, deleted, blurred: () => blurred };
}

describe("QueuePanelComponent", () => {
	test("an empty queue renders nothing and reports itself invisible", () => {
		const { panel } = build([]);
		expect(panel.visible).toBe(false);
		expect(panel.render(80)).toEqual([]);
	});

	test("lists the queue with a count and a key hint", () => {
		const { panel } = build();
		const text = renderPlain(panel.render(80));
		expect(text).toContain("queue · 2 waiting");
		expect(text).toContain("1. first");
		expect(text).toContain("2. second");
	});

	test("only a window of items is shown, with the rest counted", () => {
		const { panel } = build(items("a", "b", "c", "d", "e"));
		const text = renderPlain(panel.render(80));
		expect(text).toContain("1. a");
		expect(text).toContain(`${QUEUE_WINDOW}. c`);
		expect(text).not.toContain("4. d");
		expect(text).toContain("…2 more");
	});

	test("the window slides to keep the selection visible", () => {
		const { panel } = build(items("a", "b", "c", "d", "e"));
		panel.focused = true;
		for (let i = 0; i < 4; i++) panel.handleInput("\x1b[B");
		expect(panel.selectedIndex).toBe(4);
		const text = renderPlain(panel.render(80));
		expect(text).toContain("5. e");
		expect(text).not.toContain("1. a");
	});

	test("enter edits, d deletes, esc unfocuses", () => {
		const { panel, edited, deleted, blurred } = build();
		panel.focused = true;
		panel.handleInput("\x1b[B");
		panel.handleInput("\r");
		expect(edited.map((item) => item.text)).toEqual(["second"]);

		panel.handleInput("d");
		expect(deleted.map((item) => item.text)).toEqual(["second"]);

		panel.handleInput("\x1b");
		expect(blurred()).toBe(1);
	});

	test("the selection stays on its row when the item under it is deleted", () => {
		const { panel } = build(items("a", "b", "c"));
		panel.focused = true;
		panel.handleInput("\x1b[B");
		expect(panel.selected?.text).toBe("b");
		panel.update(items("a", "c"));
		expect(panel.selected?.text).toBe("c");
	});

	test("offline mirrors are marked and cannot be walked past the list", () => {
		const { panel } = build([
			{ id: "q-1", text: "local one", state: "queued-local", at: 0 },
			{ id: "offline:1", text: "parked one", state: "waiting-connection", at: 0 },
		]);
		panel.focused = true;
		// Up at the head and down at the tail are both no-ops, not wraps.
		panel.handleInput("\x1b[A");
		expect(panel.selectedIndex).toBe(0);
		panel.handleInput("\x1b[B");
		panel.handleInput("\x1b[B");
		expect(panel.selectedIndex).toBe(1);
		expect(renderPlain(panel.render(80))).toContain("(offline) parked one");
	});

	test("multi-line prompts are flattened onto one row", () => {
		const { panel } = build(items("first line\nsecond line"));
		expect(renderPlain(panel.render(80))).toContain("1. first line second line");
	});

	test("no row exceeds the render width, however long the prompt", () => {
		const { panel } = build(items(`a very long prompt ${"x".repeat(300)}`, "short"));
		for (const width of [120, 80, 40, 20, 8]) {
			for (const row of panel.render(width)) {
				expect(visibleWidth(row)).toBeLessThanOrEqual(width);
			}
		}
	});

	test("unchanged input returns the very same rows array", () => {
		const { panel } = build();
		const first = panel.render(80);
		expect(panel.render(80)).toBe(first);
		panel.focused = true;
		expect(panel.render(80)).not.toBe(first);
	});
});
