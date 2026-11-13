import { expect, test } from "bun:test";
import { MAX_USER_PROMPT_HTML_BYTES, parseUserPrompt } from "../../src/protocol/user-prompt.ts";

const base = { promptId: "p1", sessionKey: "s1", runId: "r1" };
const FORM = '<form><input type="number" name="n" value="2"></form>';

test("parses a question request", () => {
	const event = parseUserPrompt({
		...base,
		questions: [{ id: "q", question: "Pick", options: [{ label: "A" }] }],
	});
	expect(event?.questions).toHaveLength(1);
	expect(event?.html).toBeUndefined();
});

test("parses an html form request without questions", () => {
	for (const questions of [[], undefined]) {
		const event = parseUserPrompt({ ...base, questions, html: FORM, expiresAtMs: 5 });
		expect(event).toMatchObject({ promptId: "p1", html: FORM, questions: [], expiresAtMs: 5 });
	}
});

test("rejects malformed form requests instead of rendering something else", () => {
	expect(parseUserPrompt({ ...base, questions: [], html: "  " })).toBeUndefined();
	expect(parseUserPrompt({ ...base, questions: [], html: 7 })).toBeUndefined();
	expect(
		parseUserPrompt({ ...base, questions: [], html: "x".repeat(MAX_USER_PROMPT_HTML_BYTES + 1) }),
	).toBeUndefined();
	expect(
		parseUserPrompt({
			...base,
			html: FORM,
			questions: [{ id: "q", question: "Pick", options: [] }],
		}),
	).toBeUndefined();
	expect(parseUserPrompt({ ...base, questions: [] })).toBeUndefined();
});
