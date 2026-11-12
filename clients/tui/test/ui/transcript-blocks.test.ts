import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import {
	setTranscriptActionHandler,
	type TranscriptAction,
} from "@oh-my-pi/pi-tui/chat/transcript-actions";
import type { NativeNode } from "@oh-my-pi/pi-tui/native/node";
import { setNativeButtons } from "@oh-my-pi/pi-tui/native/state";
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
	setNativeButtons(false);
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

	test.each([false, true])(
		"Copy keeps its action and identity with native buttons=%s",
		(buttons) => {
			setNativeButtons(buttons);
			const copied: TranscriptAction[] = [];
			setTranscriptActionHandler((action) => copied.push(action));
			try {
				const component = new UserMessageComponent("copy this");
				const toolbar = component.describe().c?.[0];
				if (!toolbar || !("k" in toolbar)) throw new Error("expected user toolbar");
				expect(toolbar.c?.[0]).toMatchObject({
					k: buttons ? "button" : "icon",
					key: "copy",
					p: { role: "omp.user.tool", aria: "Copy message", actions: { click: "copy-message" } },
				});
				component.handleNativeEvent({
					type: "action",
					key: "tools/copy",
					act: "copy-message",
					mods: [],
				});
				expect(copied).toEqual([{ act: "copy", text: "copy this" }]);
			} finally {
				setTranscriptActionHandler(undefined);
			}
		},
	);
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

	test("publishes only the markdown frozen source prefix", () => {
		const component = new AssistantMessageComponent();
		component.updateContent("first paragraph\n\nsecond paragraph still growing");
		const lines = component.render(WIDTH);
		const stable = component.renderTranscriptStableRows(
			component.getTranscriptStableRows().length,
			WIDTH,
		);
		expect(stable.length).toBeGreaterThan(0);
		expect(stable.length).toBeLessThan(lines.length);
		expect(lines.slice(0, stable.length)).toEqual([...stable]);
	});

	test("finalization preserves already-published identities for history replay", () => {
		const component = new AssistantMessageComponent();
		component.updateContent("a\n\nb\n\nc");
		component.render(WIDTH);
		const keys = component.getTranscriptStableRows().map((row) => row.key);
		component.finalize({ ok: true });
		component.render(WIDTH);
		expect(component.getTranscriptStableRows().map((row) => row.key)).toEqual(keys);
	});

	test("stable publications never shrink while text only grows", () => {
		const component = new AssistantMessageComponent();
		let previous = 0;
		for (const text of ["one\n\n", "one\n\ntwo\n\n", "one\n\ntwo\n\nthree\n\nfour"]) {
			component.updateContent(text);
			component.render(WIDTH);
			const settled = component.getTranscriptStableRows().length;
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

	test.each([false, true])(
		"only the reported turn offers Copy with native buttons=%s",
		(buttons) => {
			setNativeButtons(buttons);
			const copied: TranscriptAction[] = [];
			setTranscriptActionHandler((action) => copied.push(action));
			try {
				const roles = (node: NativeNode) =>
					(node.c ?? []).map((child) => ("k" in child ? child.p?.role : "component"));
				const earlier = new AssistantMessageComponent("Looking first.");
				earlier.finalize({});
				expect(roles(earlier.describe())).toEqual([undefined]);

				const last = new AssistantMessageComponent("half");
				last.finalize({ interrupted: true, turn: { durationMs: 4200 } });
				const described = last.describe();
				expect(described.c?.[0]).toMatchObject({ k: "md", p: { text: "half" } });
				expect(roles(described)).toEqual([undefined, "omp.assistant.abort", "omp.turn.usage"]);
				expect(last.describe()).toBe(described);
				const footer = described.c?.[2];
				if (!footer || !("k" in footer)) throw new Error("expected turn footer");
				expect(footer.c?.[0]).toMatchObject({
					k: buttons ? "button" : "icon",
					key: "copy",
					p: { role: "omp.turn.copy", aria: "Copy answer", actions: { click: "copy-answer" } },
				});
				last.handleNativeEvent({
					type: "action",
					key: "turn-usage/copy",
					act: "copy-answer",
					mods: [],
				});
				expect(copied).toEqual([{ act: "copy", text: "half" }]);
			} finally {
				setTranscriptActionHandler(undefined);
			}
		},
	);
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

	test("retirement stops before an unfinished block and resumes on finalization", () => {
		const container = new TranscriptContainer();
		container.addChild(new UserMessageComponent("hello"));
		const assistant = new AssistantMessageComponent();
		assistant.updateContent("frozen paragraph\n\nstill streaming");
		container.addChild(assistant);
		container.addChild(new NoticeComponent("after the reply"));
		const prefix = container.peekFlushBatch(WIDTH)!;
		expect(renderPlain(prefix.rows)).toContain("hello");
		expect(renderPlain(prefix.rows)).not.toContain("after the reply");
		container.acknowledgeFinalizedBatch(prefix.id);
		expect(container.peekFlushBatch(WIDTH)).toBeUndefined();

		assistant.finalize({ ok: true });
		const remainder = container.peekFlushBatch(WIDTH)!;
		expect(renderPlain(remainder.rows)).toContain("still streaming");
		expect(renderPlain(remainder.rows)).toContain("after the reply");
		container.acknowledgeFinalizedBatch(remainder.id);
		expect(container.peekFlushBatch(WIDTH)).toBeUndefined();
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
