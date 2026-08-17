import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { visibleWidth } from "@oh-my-pi/pi-tui/utils";
import { AssistantMessageComponent } from "../../src/ui/components/assistant-message.ts";
import { NoticeComponent } from "../../src/ui/components/notice-message.ts";
import { TranscriptContainer } from "../../src/ui/components/transcript-container.ts";
import { UserMessageComponent } from "../../src/ui/components/user-message.ts";
import { initTheme, resetTheme } from "../../src/ui/theme/theme.ts";
import { invalidateThemeAdapters } from "../../src/ui/theme/tui-adapters.ts";
import { renderPlain } from "../helpers/memory-terminal.ts";

const WIDTH = 80;

beforeEach(() => {
	initTheme({ colorLevel: 3 });
});

afterEach(() => {
	resetTheme();
	invalidateThemeAdapters();
});

function fitsWidth(lines: readonly string[], width = WIDTH): boolean {
	return lines.every((line) => visibleWidth(line) <= width);
}

describe("UserMessageComponent", () => {
	test("renders the prompt behind the marker and fits the width", () => {
		const component = new UserMessageComponent("what is the status?");
		const lines = component.render(WIDTH);
		expect(renderPlain(lines)).toBe("❯ what is the status?");
		expect(fitsWidth(lines)).toBe(true);
	});

	test("wraps long prompts without exceeding the width", () => {
		const component = new UserMessageComponent("lorem ipsum dolor sit amet ".repeat(12));
		for (const width of [24, 40, 80, 120]) {
			expect(fitsWidth(component.render(width), width)).toBe(true);
		}
	});

	test("returns the same array reference while unchanged", () => {
		const component = new UserMessageComponent("stable");
		expect(component.render(WIDTH)).toBe(component.render(WIDTH));
	});

	test("is finalized from birth (no FinalizableBlock methods)", () => {
		const component = new UserMessageComponent("hi") as unknown as {
			isTranscriptBlockFinalized?: () => boolean;
		};
		expect(component.isTranscriptBlockFinalized).toBeUndefined();
	});
});

describe("AssistantMessageComponent", () => {
	test("renders markdown and fits the width", () => {
		const component = new AssistantMessageComponent();
		component.updateContent("# Heading\n\nsome **bold** words");
		const lines = component.render(WIDTH);
		const text = renderPlain(lines);
		expect(text).toContain("Heading");
		expect(text).toContain("bold");
		expect(fitsWidth(lines)).toBe(true);
	});

	test("stays unfinalized while streaming and seals on finalize", () => {
		const component = new AssistantMessageComponent();
		component.updateContent("streaming…");
		expect(component.isTranscriptBlockFinalized()).toBe(false);
		component.finalize({ ok: true });
		expect(component.isTranscriptBlockFinalized()).toBe(true);
	});

	test("bumps the block version on every mutation", () => {
		const component = new AssistantMessageComponent();
		const before = component.getTranscriptBlockVersion();
		component.updateContent("one");
		component.updateContent("one two");
		expect(component.getTranscriptBlockVersion()).toBeGreaterThan(before);
	});

	test("declares settled rows only from the markdown frozen prefix", () => {
		const component = new AssistantMessageComponent();
		component.updateContent("first paragraph\n\nsecond paragraph still growing");
		const lines = component.render(WIDTH);
		const settled = component.getTranscriptBlockSettledRows();
		// Never over-declare: the settled prefix cannot exceed what was rendered,
		// and the still-growing tail paragraph must stay outside it.
		expect(settled).toBeGreaterThan(0);
		expect(settled).toBeLessThan(lines.length);
	});

	test("declares no settled rows once finalized", () => {
		const component = new AssistantMessageComponent();
		component.updateContent("a\n\nb\n\nc");
		component.render(WIDTH);
		component.finalize({ ok: true });
		component.render(WIDTH);
		expect(component.getTranscriptBlockSettledRows()).toBe(0);
	});

	test("settled rows never shrink while text only grows", () => {
		const component = new AssistantMessageComponent();
		let previous = 0;
		for (const text of ["one\n\n", "one\n\ntwo\n\n", "one\n\ntwo\n\nthree\n\nfour"]) {
			component.updateContent(text);
			component.render(WIDTH);
			const settled = component.getTranscriptBlockSettledRows();
			expect(settled).toBeGreaterThanOrEqual(previous);
			previous = settled;
		}
	});

	test("an interrupted finalize keeps the partial text and marks it", () => {
		const component = new AssistantMessageComponent();
		component.updateContent("half a thou");
		component.finalize({ interrupted: true });
		const text = renderPlain(component.render(WIDTH));
		expect(text).toContain("half a thou");
		expect(text).toContain("[interrupted]");
	});

	test("a failed run renders its error under the body", () => {
		const component = new AssistantMessageComponent();
		component.updateContent("partial");
		component.finalize({ ok: false, error: "provider exploded" });
		const text = renderPlain(component.render(WIDTH));
		expect(text).toContain("partial");
		expect(text).toContain("Error: provider exploded");
	});
});

describe("TranscriptContainer", () => {
	test("separates blocks with exactly one blank row", () => {
		const container = new TranscriptContainer();
		container.addChild(new UserMessageComponent("hello"));
		container.addChild(new NoticeComponent("connected"));
		expect(renderPlain(container.render(WIDTH)).split("\n")).toEqual([
			"❯ hello",
			"",
			" · connected",
		]);
	});

	test("the commit seam stops at the first unfinalized block", () => {
		const container = new TranscriptContainer();
		container.addChild(new UserMessageComponent("hello"));
		const assistant = new AssistantMessageComponent();
		assistant.updateContent("frozen paragraph\n\nstill streaming");
		container.addChild(assistant);
		container.render(WIDTH);

		const seam = container.getNativeScrollbackLiveRegionStart();
		const rows = container.render(WIDTH).length;
		expect(seam).toBeGreaterThan(0);
		expect(seam).toBeLessThan(rows);

		assistant.finalize({ ok: true });
		container.render(WIDTH);
		// Nothing is live any more: the whole transcript is committable.
		expect(container.getNativeScrollbackLiveRegionStart()).toBeUndefined();
	});

	test("returns the same array reference when nothing changed", () => {
		const container = new TranscriptContainer();
		container.addChild(new UserMessageComponent("hello"));
		const first = container.render(WIDTH);
		expect(container.render(WIDTH)).toBe(first);
	});

	test("every row fits the requested width at any width", () => {
		const container = new TranscriptContainer();
		container.addChild(new UserMessageComponent("a fairly long prompt ".repeat(6)));
		const assistant = new AssistantMessageComponent();
		assistant.updateContent("```js\nconst x = 1;\n```\n\n| a | b |\n| - | - |\n| 1 | 2 |");
		container.addChild(assistant);
		for (const width of [24, 40, 80, 120]) {
			expect(fitsWidth(container.render(width), width)).toBe(true);
		}
	});
});

describe("narrow widths", () => {
	// pi-tui keeps a component's horizontal padding at every width — its content
	// width floors at 1 — so a padded block emits rows wider than requested
	// unless the component clamps them. The render contract has no exception for
	// small terminals.
	const NARROW = [1, 2, 3, 4, 5, 6, 8, 12];

	test("a user message never exceeds the width", () => {
		const component = new UserMessageComponent("what is the status?");
		for (const width of NARROW) {
			expect(fitsWidth(component.render(width), width)).toBe(true);
		}
	});

	test("an assistant message never exceeds the width", () => {
		const component = new AssistantMessageComponent();
		component.updateContent("# Heading\n\nsome **bold** words and `code`");
		for (const width of NARROW) {
			expect(fitsWidth(component.render(width), width)).toBe(true);
		}
	});

	test("a notice never exceeds the width", () => {
		const component = new NoticeComponent("connected to lemon 0.1.0");
		for (const width of NARROW) {
			expect(fitsWidth(component.render(width), width)).toBe(true);
		}
	});

	test("the assembled transcript never exceeds the width", () => {
		const container = new TranscriptContainer();
		container.addChild(new UserMessageComponent("hello there"));
		container.addChild(new NoticeComponent("reconnected", "warning"));
		const assistant = new AssistantMessageComponent();
		assistant.updateContent("a reply with a fairly long line in it");
		container.addChild(assistant);
		for (const width of NARROW) {
			expect(fitsWidth(container.render(width), width)).toBe(true);
		}
	});

	test("clamping keeps the same array reference across identical renders", () => {
		const component = new UserMessageComponent("hello there");
		const first = component.render(4);
		expect(component.render(4)).toBe(first);
	});
});
