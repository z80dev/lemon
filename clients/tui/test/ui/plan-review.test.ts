import { describe, expect, test } from "bun:test";
import { composeRefineFeedback, removedSections } from "../../src/ui/plan-review.ts";

const PLAN =
	"intro\n\n# Plan\n\n## Step one\n\ntext\n\n### Detail\n\n## Step two\n\n```md\n# not a heading\n```\n";

describe("removedSections", () => {
	test("is empty for an unchanged plan", () => {
		expect(removedSections(PLAN, PLAN)).toEqual([]);
	});

	test("lists a removed heading and its nested sections, ignoring fenced hashes", () => {
		const edited = "intro\n\n# Plan\n\n## Step two\n\n```md\n# not a heading\n```\n";
		expect(removedSections(PLAN, edited)).toEqual(["Step one", "Detail"]);
	});

	test("counts duplicate titles once per occurrence", () => {
		const twice = "# A\n\n## Same\n\n## Same\n";
		expect(removedSections(twice, "# A\n\n## Same\n")).toEqual(["Same"]);
	});
});

describe("composeRefineFeedback", () => {
	const header = "Refinement feedback on the plan:\n";

	test("says nothing when there is nothing to say", () => {
		expect(composeRefineFeedback("", [])).toBe("");
	});

	test("passes annotations through unchanged", () => {
		const overlay = `${header}\n## Step one\n- too vague\n`;
		expect(composeRefineFeedback(overlay, [])).toBe(overlay);
	});

	test("replaces the overlay's own removal list with the full diff", () => {
		const overlay = `${header}\nRemove these sections:\n- Detail\n\n## Step two\n- split this\n`;
		expect(composeRefineFeedback(overlay, ["Step one", "Detail"])).toBe(
			`${header}\nRemove these sections:\n- Step one\n- Detail\n\n## Step two\n- split this\n`,
		);
	});

	test("carries removals alone", () => {
		expect(composeRefineFeedback("", ["Step one"])).toBe(
			`${header}\nRemove these sections:\n- Step one\n`,
		);
	});
});
