import { describe, expect, test } from "bun:test";
import type { Component } from "@oh-my-pi/pi-tui/tui";
import {
	CATCHUP_FRAMES,
	MIN_STEP,
	nextStep,
	StreamingRevealController,
	StreamUnitCounter,
} from "../../src/ui/controllers/streaming-reveal.ts";
import { waitFor } from "../helpers/wait.ts";

/** Minimal reveal target: records what it was told to show. */
class FakeTarget implements Component {
	text = "";
	renders = 0;

	updateContent(text: string): void {
		this.text = text;
	}

	render(): readonly string[] {
		this.renders += 1;
		return [this.text];
	}
}

describe("nextStep", () => {
	test("never falls below the minimum step", () => {
		expect(nextStep(0)).toBe(MIN_STEP);
		expect(nextStep(1)).toBe(MIN_STEP);
	});

	test("clears a backlog within the catch-up window", () => {
		const backlog = 800;
		expect(nextStep(backlog)).toBe(Math.ceil(backlog / CATCHUP_FRAMES));
	});
});

describe("StreamUnitCounter", () => {
	test("counts graphemes, not code units", () => {
		const counter = new StreamUnitCounter();
		expect(counter.count("👩‍👩‍👧‍👦")).toBe(1);
		expect(counter.count("héllo")).toBe(5);
	});

	test("slicing never splits a grapheme cluster", () => {
		const counter = new StreamUnitCounter();
		const text = "a👩‍👩‍👧‍👦b";
		expect(counter.slice(text, 1)).toBe("a");
		expect(counter.slice(text, 2)).toBe("a👩‍👩‍👧‍👦");
		expect(counter.slice(text, 3)).toBe(text);
		expect(counter.slice(text, 99)).toBe(text);
	});

	test("incremental appends agree with a cold count", () => {
		const incremental = new StreamUnitCounter();
		const cold = new StreamUnitCounter();
		let text = "";
		for (const chunk of ["héllo ", "wörld ", "👩‍👩‍👧‍👦 ", "done"]) {
			text += chunk;
			incremental.count(text);
			expect(incremental.count(text)).toBe(cold.count(text));
			cold.reset();
		}
		expect(incremental.slice(text, 8)).toBe(new StreamUnitCounter().slice(text, 8));
	});
});

describe("StreamingRevealController", () => {
	test("reveals progressively and lands the whole text", async () => {
		const target = new FakeTarget();
		const rendered: Component[] = [];
		const reveal = new StreamingRevealController({
			requestRender: (component) => rendered.push(component),
		});
		const text = "the quick brown fox jumps over the lazy dog";
		reveal.begin(target, text);
		// Nothing is revealed on the first frame; the timer does the work.
		expect(target.text).toBe("");
		await waitFor(() => target.text === text, { what: "the full reveal" });
		expect(rendered.length).toBeGreaterThan(0);
		expect(rendered.every((component) => component === target)).toBe(true);
		expect(reveal.running).toBe(false);
		reveal.stop();
	});

	test("finish() lands everything at once and stops the timer", () => {
		const target = new FakeTarget();
		const reveal = new StreamingRevealController({ requestRender: () => {} });
		reveal.begin(target, "hello world");
		reveal.setTarget("hello world, and more");
		reveal.finish();
		expect(target.text).toBe("hello world, and more");
		expect(reveal.running).toBe(false);
		reveal.stop();
	});

	test("smooth streaming off reveals immediately and still asks for a render", () => {
		const target = new FakeTarget();
		const rendered: Component[] = [];
		const reveal = new StreamingRevealController({
			requestRender: (component) => rendered.push(component),
			getSmoothStreaming: () => false,
		});
		reveal.begin(target, "instant");
		expect(target.text).toBe("instant");
		expect(reveal.running).toBe(false);
		// No timer runs on this path, so without an explicit request nothing would
		// ever paint the text.
		expect(rendered).toEqual([target]);

		reveal.setTarget("instant, plus more");
		expect(target.text).toBe("instant, plus more");
		expect(rendered).toEqual([target, target]);
		reveal.stop();
	});

	test("a shorter target rewinds the cursor instead of over-running", () => {
		const target = new FakeTarget();
		const reveal = new StreamingRevealController({ requestRender: () => {} });
		reveal.begin(target, "a long first answer");
		reveal.finish();
		reveal.setTarget("short");
		expect(reveal.revealedUnits).toBeLessThanOrEqual(5);
		reveal.stop();
	});

	test("stop() detaches without touching the component", () => {
		const target = new FakeTarget();
		const reveal = new StreamingRevealController({ requestRender: () => {} });
		reveal.begin(target, "text");
		reveal.finish();
		reveal.stop();
		expect(target.text).toBe("text");
		expect(reveal.component).toBeUndefined();
		// A target set after stop() is a no-op: there is nothing to reveal into.
		reveal.setTarget("ignored");
		expect(target.text).toBe("text");
	});
});
